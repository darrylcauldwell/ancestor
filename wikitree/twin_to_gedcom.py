"""Export the WikiTree digital twin to a GEDCOM 5.5.1 file.

Reads `.wikitree-twin.json` (NetworkX graph saved by `python -m wikitree.twin sync`)
and writes a portable GEDCOM with INDI/FAM records, dates, places, and full bios
preserved verbatim as NOTE blocks (CONT/CONC continuation).

Citations inside bios are kept as-is — downstream parsing into structured SOUR/PAGE
records is the citation matcher's job, not this exporter's.

Usage:
    python -m wikitree.twin_to_gedcom [--input PATH] [--output PATH] [--submitter NAME]
"""
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


MONTHS = {
    1: 'JAN', 2: 'FEB', 3: 'MAR', 4: 'APR', 5: 'MAY', 6: 'JUN',
    7: 'JUL', 8: 'AUG', 9: 'SEP', 10: 'OCT', 11: 'NOV', 12: 'DEC',
}


def iso_to_gedcom_date(iso, decade=None):
    """Convert a twin ISO date (YYYY-MM-DD with 00 placeholders) to GEDCOM date.

    Falls back to ABT <decade> (e.g. ABT 1970 from "1970s") if iso is unknown
    but a decade is supplied. Returns empty string if nothing usable.
    """
    if not iso or iso == '0000-00-00':
        if decade and decade != 'unknown':
            stem = decade.rstrip('s')
            if stem.isdigit():
                return f'ABT {stem}'
        return ''
    try:
        y, m, d = iso.split('-')
        y_n = int(y) if y != '0000' else 0
        m_n = int(m) if m != '00' else 0
        d_n = int(d) if d != '00' else 0
    except (ValueError, AttributeError):
        return ''
    if not y_n:
        return ''
    if m_n and d_n:
        return f'{d_n} {MONTHS[m_n]} {y_n}'
    if m_n:
        return f'{MONTHS[m_n]} {y_n}'
    return str(y_n)


def emit_text(text, base_level, tag, max_line=200):
    """Emit a multi-line text payload as GEDCOM tag + CONT/CONC continuation lines.

    Maps embedded newlines to CONT; splits any single line longer than max_line
    into CONC chunks. Returns a list of GEDCOM lines (no trailing newlines).
    """
    if text is None:
        text = ''
    raw_lines = text.replace('\r\n', '\n').replace('\r', '\n').split('\n')
    out = []
    first = True
    for line in raw_lines:
        if first:
            prefix = f'{base_level} {tag} '
            first = False
        else:
            prefix = f'{base_level + 1} CONT '
        conc_prefix = f'{base_level + 1} CONC '
        if len(line) <= max_line:
            out.append(prefix + line)
        else:
            out.append(prefix + line[:max_line])
            tail = line[max_line:]
            while tail:
                out.append(conc_prefix + tail[:max_line])
                tail = tail[max_line:]
    return out


def build_families(nodes):
    """Aggregate FAM records from each node's Father/Mother/Spouses arrays.

    Returns dict keyed by frozenset({parent_id, ...}); values carry husb/wife/
    children/marriage_date/marriage_loc. The frozenset key dedupes the two-sided
    spouse references automatically.
    """
    families = {}

    def get_or_create(key):
        return families.setdefault(key, {
            'husb': None,
            'wife': None,
            'children': set(),
            'marriage_date': '',
            'marriage_loc': '',
        })

    # Pass 1: parent pairs reachable via children's Father/Mother
    for n in nodes:
        father = n.get('Father') or None
        mother = n.get('Mother') or None
        if not father and not mother:
            continue
        key = frozenset(x for x in (father, mother) if x)
        if not key:
            continue
        fam = get_or_create(key)
        if father:
            fam['husb'] = father
        if mother:
            fam['wife'] = mother
        fam['children'].add(n['Id'])

    # Pass 2: spouse pairs from each node's Spouses array
    for n in nodes:
        self_id = n['Id']
        self_gender = n.get('Gender')
        for sp in (n.get('Spouses') or []):
            try:
                sp_id = int(sp.get('Id'))
            except (TypeError, ValueError):
                continue
            key = frozenset({self_id, sp_id})
            fam = get_or_create(key)
            sp_gender = sp.get('Gender')
            for (ind_id, gender) in ((self_id, self_gender), (sp_id, sp_gender)):
                if gender == 'Male' and not fam['husb']:
                    fam['husb'] = ind_id
                elif gender == 'Female' and not fam['wife']:
                    fam['wife'] = ind_id
            md = sp.get('MarriageDate') or ''
            ml = sp.get('MarriageLocation') or ''
            if md and md != '0000-00-00' and not fam['marriage_date']:
                fam['marriage_date'] = md
            if ml and not fam['marriage_loc']:
                fam['marriage_loc'] = ml

    return families


def emit_indi(node, indi_xref, famc, fams_list):
    """Emit one INDI record (with names, sex, birth, death, FAMC/FAMS, bio NOTE)."""
    lines = [f'0 @{indi_xref}@ INDI']

    first = (node.get('FirstName') or '').strip()
    middle = (node.get('MiddleName') or '').strip()
    surname = (node.get('LastNameAtBirth') or '').strip()
    suffix = (node.get('Suffix') or '').strip()
    prefix = (node.get('Prefix') or '').strip()
    given = ' '.join(p for p in (first, middle) if p).strip()

    name_parts = []
    if prefix:
        name_parts.append(prefix)
    if given:
        name_parts.append(given)
    name_parts.append(f'/{surname}/' if surname else '//')
    if suffix:
        name_parts.append(suffix)
    lines.append('1 NAME ' + ' '.join(name_parts))
    if prefix:
        lines.append('2 NPFX ' + prefix)
    if given:
        lines.append('2 GIVN ' + given)
    if surname:
        lines.append('2 SURN ' + surname)
    if suffix:
        lines.append('2 NSFX ' + suffix)

    lnc = (node.get('LastNameCurrent') or '').strip()
    if lnc and lnc != surname:
        married_parts = []
        if given:
            married_parts.append(given)
        married_parts.append(f'/{lnc}/')
        lines.append('1 NAME ' + ' '.join(married_parts))
        lines.append('2 TYPE married')
        if given:
            lines.append('2 GIVN ' + given)
        lines.append('2 SURN ' + lnc)

    g = node.get('Gender')
    if g == 'Male':
        lines.append('1 SEX M')
    elif g == 'Female':
        lines.append('1 SEX F')

    bdate = iso_to_gedcom_date(node.get('BirthDate'), node.get('BirthDateDecade'))
    bplac = (node.get('BirthLocation') or '').strip()
    if bdate or bplac:
        lines.append('1 BIRT')
        if bdate:
            lines.append('2 DATE ' + bdate)
        if bplac:
            lines.append('2 PLAC ' + bplac)

    ddate = iso_to_gedcom_date(node.get('DeathDate'), node.get('DeathDateDecade'))
    dplac = (node.get('DeathLocation') or '').strip()
    if ddate or dplac:
        lines.append('1 DEAT')
        if ddate:
            lines.append('2 DATE ' + ddate)
        if dplac:
            lines.append('2 PLAC ' + dplac)

    if famc:
        lines.append(f'1 FAMC @{famc}@')
    for fams in fams_list:
        lines.append(f'1 FAMS @{fams}@')

    bio = node.get('bio')
    if bio:
        lines.extend(emit_text(bio, base_level=1, tag='NOTE'))

    wt_name = (node.get('Name') or '').strip()
    if wt_name:
        lines.append('1 _WIKI_ID ' + wt_name)

    # WikiTree privacy: lower number = more restrictive
    # (10 Unlisted, 20 Private, 30-40 partially-private, 50 Public, 60 Open)
    privacy = node.get('Privacy', 0)
    if privacy and privacy <= 10:
        lines.append('1 RESN confidential')
    elif privacy and privacy <= 20:
        lines.append('1 RESN privacy')

    return lines


def emit_fam(fam, fam_xref, indi_xref_by_id):
    """Emit one FAM record (HUSB, WIFE, CHIL, optional MARR)."""
    lines = [f'0 @{fam_xref}@ FAM']
    if fam['husb'] and fam['husb'] in indi_xref_by_id:
        lines.append(f'1 HUSB @{indi_xref_by_id[fam["husb"]]}@')
    if fam['wife'] and fam['wife'] in indi_xref_by_id:
        lines.append(f'1 WIFE @{indi_xref_by_id[fam["wife"]]}@')
    for c in sorted(fam['children']):
        if c in indi_xref_by_id:
            lines.append(f'1 CHIL @{indi_xref_by_id[c]}@')
    if fam['marriage_date'] or fam['marriage_loc']:
        lines.append('1 MARR')
        mdate = iso_to_gedcom_date(fam['marriage_date'])
        if mdate:
            lines.append('2 DATE ' + mdate)
        if fam['marriage_loc']:
            lines.append('2 PLAC ' + fam['marriage_loc'])
    return lines


def export(twin_path, out_path, submitter, include_wt_ids=None):
    data = json.loads(Path(twin_path).read_text())
    all_nodes = data['graph']['nodes']
    synced_at = data.get('synced_at', '')

    if include_wt_ids:
        # Filter to the requested WikiTree IDs (e.g. "Cauldwell-100"); strip
        # parent/spouse refs that point outside the set so the resulting
        # GEDCOM has no orphan xrefs.
        wanted = set(include_wt_ids)
        nodes = [n for n in all_nodes if n.get('Name') in wanted]
        included_int_ids = {n['Id'] for n in nodes}
        # Rewrite each node to null out Father/Mother/Spouses that fall
        # outside the include set. The wrapped objects are shallow-copied
        # so we don't mutate the loaded twin data.
        cleaned = []
        for n in nodes:
            n2 = dict(n)
            if n2.get('Father') and n2['Father'] not in included_int_ids:
                n2['Father'] = 0
            if n2.get('Mother') and n2['Mother'] not in included_int_ids:
                n2['Mother'] = 0
            sps = []
            for sp in (n2.get('Spouses') or []):
                try:
                    sp_id = int(sp.get('Id'))
                except (TypeError, ValueError):
                    continue
                if sp_id in included_int_ids:
                    sps.append(sp)
            n2['Spouses'] = sps
            cleaned.append(n2)
        nodes = cleaned
    else:
        nodes = all_nodes

    indi_xref_by_id = {n['Id']: f'I{n["Id"]}' for n in nodes}

    families = build_families(nodes)
    fam_keys_sorted = sorted(families.keys(), key=lambda k: tuple(sorted(k)))
    fam_xref_by_key = {k: f'F{i + 1}' for i, k in enumerate(fam_keys_sorted)}

    famc_by_indi = {}
    fams_by_indi = {}
    for key in fam_keys_sorted:
        fam = families[key]
        fam_xref = fam_xref_by_key[key]
        for c in fam['children']:
            famc_by_indi[c] = fam_xref
        for sp_id in (fam['husb'], fam['wife']):
            if sp_id:
                fams_by_indi.setdefault(sp_id, []).append(fam_xref)

    today = datetime.now(timezone.utc).strftime('%d %b %Y').upper()
    out_lines = [
        '0 HEAD',
        '1 SOUR ancestor-twin-export',
        '2 NAME twin_to_gedcom.py',
        '2 VERS 1.0',
        '1 DEST GEDCOM',
        f'1 DATE {today}',
        '1 CHAR UTF-8',
        '1 GEDC',
        '2 VERS 5.5.1',
        '2 FORM LINEAGE-LINKED',
        '1 SUBM @SUBM1@',
    ]
    if synced_at:
        out_lines.append('1 NOTE Source twin synced at ' + synced_at)

    out_lines.append('0 @SUBM1@ SUBM')
    out_lines.append('1 NAME ' + submitter)

    for n in sorted(nodes, key=lambda x: x['Id']):
        out_lines.extend(emit_indi(
            n,
            indi_xref=indi_xref_by_id[n['Id']],
            famc=famc_by_indi.get(n['Id']),
            fams_list=fams_by_indi.get(n['Id'], []),
        ))

    for key in fam_keys_sorted:
        out_lines.extend(emit_fam(
            families[key],
            fam_xref=fam_xref_by_key[key],
            indi_xref_by_id=indi_xref_by_id,
        ))

    out_lines.append('0 TRLR')

    Path(out_path).write_text('\n'.join(out_lines) + '\n', encoding='utf-8')

    indi_count = len(nodes)
    fam_count = len(families)
    note_count = sum(1 for n in nodes if n.get('bio'))
    living_count = sum(1 for n in nodes if n.get('IsLiving') == 1)
    fams_with_marr_data = sum(1 for k in families
                              if families[k]['marriage_date'] or families[k]['marriage_loc'])
    print(f'Wrote {out_path}')
    print(f'  INDI:                       {indi_count}')
    print(f'  FAM:                        {fam_count}')
    print(f'  FAM with marriage date/loc: {fams_with_marr_data}')
    print(f'  bios preserved as NOTE:     {note_count}')
    print(f'  IsLiving=1 (preserved):     {living_count}')


def main():
    parser = argparse.ArgumentParser(
        prog='python -m wikitree.twin_to_gedcom',
        description='Export the WikiTree digital twin to GEDCOM 5.5.1.'
    )
    parser.add_argument('--input', default='.wikitree-twin.json',
                        help='Twin JSON path (default: .wikitree-twin.json)')
    parser.add_argument('--output', default='Cauldwell Family Tree.twin-export.ged',
                        help='Output GEDCOM path')
    parser.add_argument('--submitter', default='Darryl Cauldwell',
                        help='Name to use for the SUBM record')
    parser.add_argument('--include', default=None,
                        help='Comma-separated WikiTree IDs to include '
                             '(e.g. "Cauldwell-100,Cauldwell-102"). When set, '
                             'parent/spouse refs to non-included individuals '
                             'are stripped so no orphan xrefs land in the output.')
    args = parser.parse_args()

    if not Path(args.input).exists():
        raise SystemExit(f'Input not found: {args.input}')
    include = [s.strip() for s in args.include.split(',')] if args.include else None
    export(args.input, args.output, args.submitter, include_wt_ids=include)


if __name__ == '__main__':
    main()
