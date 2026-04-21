"""CLI entry point for the WikiTree SDK.

Usage:
  python -m wikitree login          — authenticate and save API session
  python -m wikitree check          — verify API session is valid
  python -m wikitree test [WT_ID]   — fetch + print a profile
  python -m wikitree search --first X --last Y  — search profiles
  python -m wikitree login-web      — interactive Playwright login for editor
  python -m wikitree check-web      — verify editor session
  python -m wikitree create FILE    — create profiles from JSON file
  python -m wikitree create-one --first X --last Y --birth-date YYYY  — create single profile
  python -m wikitree link FILE      — link existing profiles from JSON file
  python -m wikitree link-one PERSON_ID RELATIONSHIP TARGET_WT_ID  — link single relationship

Environment variables:
  WIKITREE_EMAIL      — WikiTree account email
  WIKITREE_PASSWORD   — WikiTree account password
"""
import json
import os
import sys

from .api import WikiTreeAPI


def _get_api():
    """Build a WikiTreeAPI from environment variables."""
    email = os.environ.get("WIKITREE_EMAIL")
    password = os.environ.get("WIKITREE_PASSWORD")
    if not email or not password:
        raise SystemExit(
            "Set WIKITREE_EMAIL and WIKITREE_PASSWORD environment variables.\n"
            "Tip: add them to a .env file and run `source .env` first."
        )
    return WikiTreeAPI(email=email, password=password)


def cmd_login():
    api = _get_api()
    me = api.login()
    print(f"✓ Authenticated as {me['user_name']} "
          f"(id={me['user_id']}, watchlist={me['watchlist_count']})")


def cmd_check():
    api = _get_api()
    me = api.login()
    if me:
        print(f"✓ Session valid — {me['user_name']} "
              f"(id={me['user_id']}, watchlist={me['watchlist_count']})")
    else:
        print("✗ Session invalid or expired. Run `python -m wikitree login`.")
        sys.exit(1)


def cmd_test(wt_id="Cauldwell-103"):
    api = _get_api()
    api.login()
    profile = api.get_profile(wt_id)
    if profile:
        bio = profile.pop("bio", "") if "bio" in profile else ""
        Bio = profile.pop("Bio", "") if "Bio" in profile else ""
        print(json.dumps(profile, indent=2, default=str))
        bio_text = bio or Bio
        if bio_text:
            print(f"\n[bio: {len(bio_text)} chars — preview]\n{bio_text[:300]}...")
    else:
        print(f"No profile returned for {wt_id}")
        sys.exit(1)


def cmd_search(args):
    import argparse
    parser = argparse.ArgumentParser(prog="python -m wikitree search")
    parser.add_argument("--first", default="", help="First name")
    parser.add_argument("--last", default="", help="Last name")
    parser.add_argument("--birth", default="", help="Birth date/year")
    parser.add_argument("--death", default="", help="Death date/year")
    parser.add_argument("--birth-location", default="", help="Birth location")
    parser.add_argument("--death-location", default="", help="Death location")
    parsed = parser.parse_args(args)

    api = _get_api()
    api.login()
    matches, total = api.search_person(
        first_name=parsed.first, last_name=parsed.last,
        birth_date=parsed.birth, death_date=parsed.death,
        birth_location=parsed.birth_location,
        death_location=parsed.death_location,
    )
    print(f"Found {total} results ({len(matches)} returned):\n")
    for m in matches:
        name = f"{m.get('FirstName', '')} {m.get('LastNameAtBirth', '')}".strip()
        birth = m.get("BirthDate") or m.get("BirthDateDecade") or ""
        death = m.get("DeathDate") or m.get("DeathDateDecade") or ""
        wt_id = m.get("Name", "?")
        print(f"  {wt_id:30s}  {name:30s}  b.{birth:12s}  d.{death}")


def cmd_create(json_file):
    """Create profiles from a JSON file.

    JSON format: list of dicts, each with keys:
      first_name, last_name_at_birth, last_name_current (optional),
      middle_name, gender (Male/Female), birth_date, birth_location,
      death_date, death_location, sources, bio

    Optional family linking keys:
      reference_id (numeric user ID), relationship (father/mother/spouse/child/sibling)
    """
    from .editor import WikiTreeWebEditor

    profiles = json.loads(open(json_file).read())
    if isinstance(profiles, dict) and "profiles" in profiles:
        profiles = profiles["profiles"]

    print(f"Creating {len(profiles)} profiles...\n")

    results = []
    with WikiTreeWebEditor() as ed:
        if not ed.is_authed():
            raise SystemExit("Not authenticated. Run `python -m wikitree login-web`.")

        for i, p in enumerate(profiles, 1):
            name = f"{p.get('first_name', '')} {p.get('last_name_at_birth', '')}".strip()
            print(f"[{i}/{len(profiles)}] {name}")

            try:
                if p.get("reference_id") and p.get("relationship"):
                    result = ed.create_family_member(
                        reference_id=p["reference_id"],
                        relationship=p["relationship"],
                        first_name=p.get("first_name", ""),
                        last_name_at_birth=p.get("last_name_at_birth", ""),
                        last_name_current=p.get("last_name_current", ""),
                        middle_name=p.get("middle_name", ""),
                        gender=p.get("gender", "Male"),
                        birth_date=p.get("birth_date", ""),
                        birth_location=p.get("birth_location", ""),
                        death_date=p.get("death_date", ""),
                        death_location=p.get("death_location", ""),
                        sources=p.get("sources", ""),
                        bio=p.get("bio", ""),
                    )
                else:
                    result = ed.create_profile(
                        first_name=p.get("first_name", ""),
                        last_name_at_birth=p.get("last_name_at_birth", ""),
                        last_name_current=p.get("last_name_current", ""),
                        middle_name=p.get("middle_name", ""),
                        gender=p.get("gender", "Male"),
                        birth_date=p.get("birth_date", ""),
                        birth_location=p.get("birth_location", ""),
                        death_date=p.get("death_date", ""),
                        death_location=p.get("death_location", ""),
                        sources=p.get("sources", ""),
                        bio=p.get("bio", ""),
                    )

                wt_id = result.get("wt_id", "?")
                user_id = result.get("user_id", "?")
                print(f"  ✓ Created: {wt_id} (user_id={user_id})")
                result["input_name"] = name
                results.append(result)

            except Exception as e:
                print(f"  ✗ Error: {e}")
                results.append({"input_name": name, "error": str(e)})

    # Save results
    out = json.dumps(results, indent=2)
    out_file = json_file.replace(".json", "_results.json")
    open(out_file, "w").write(out)
    print(f"\n{'='*60}")
    print(f"Results saved to: {out_file}")
    print(f"{'='*60}")
    for r in results:
        if r.get("wt_id"):
            print(f"  ✓ {r['input_name']} → {r['wt_id']}")
        else:
            print(f"  ✗ {r['input_name']} → {r.get('error', 'unknown')}")


def cmd_link(json_file):
    """Link existing profiles as family members.

    JSON format: list of dicts, each with:
      person_id:     numeric user ID to add relative to
      relationship:  'father', 'mother', 'spouse', 'child', 'sibling'
      target_wt_id:  WikiTree ID to connect (e.g. 'Cauldwell-173')
    """
    from .editor import WikiTreeWebEditor

    links = json.loads(open(json_file).read())
    print(f"Linking {len(links)} relationships...\n")

    with WikiTreeWebEditor() as ed:
        if not ed.is_authed():
            raise SystemExit("Not authenticated. Run `python -m wikitree login-web`.")

        for i, link in enumerate(links, 1):
            person_id = link["person_id"]
            rel = link["relationship"]
            target = link["target_wt_id"]
            label = link.get("label", f"{target} as {rel}")
            print(f"[{i}/{len(links)}] {label}")

            try:
                ed.link_family_member(person_id, rel, target)
                print(f"  ✓ Linked {target} as {rel} of u={person_id}")
            except Exception as e:
                print(f"  ✗ Error: {e}")

    print("\nDone!")


def cmd_link_one(args):
    """Link a single relationship from CLI args."""
    import argparse
    from .editor import WikiTreeWebEditor

    parser = argparse.ArgumentParser(prog="python -m wikitree link-one")
    parser.add_argument("person_id", help="Numeric user ID of person to add relative to")
    parser.add_argument("relationship", choices=["father", "mother", "spouse", "child", "sibling"])
    parser.add_argument("target_wt_id", help="WikiTree ID to connect (e.g. Cauldwell-173)")
    parsed = parser.parse_args(args)

    with WikiTreeWebEditor() as ed:
        if not ed.is_authed():
            raise SystemExit("Not authenticated. Run `python -m wikitree login-web`.")

        ed.link_family_member(parsed.person_id, parsed.relationship, parsed.target_wt_id)
        print(f"✓ Linked {parsed.target_wt_id} as {parsed.relationship} of u={parsed.person_id}")


def cmd_create_one(args):
    import argparse
    from .editor import WikiTreeWebEditor

    parser = argparse.ArgumentParser(prog="python -m wikitree create-one")
    parser.add_argument("--first", required=True, help="First name")
    parser.add_argument("--middle", default="", help="Middle name")
    parser.add_argument("--last", required=True, help="Last name at birth")
    parser.add_argument("--gender", default="Male", help="Male or Female")
    parser.add_argument("--birth-date", default="", help="Birth date (YYYY-MM-DD)")
    parser.add_argument("--birth-location", default="", help="Birth location")
    parser.add_argument("--death-date", default="", help="Death date")
    parser.add_argument("--death-location", default="", help="Death location")
    parser.add_argument("--bio", default="", help="Biography text")
    parser.add_argument("--sources", default="", help="Sources")
    parsed = parser.parse_args(args)

    with WikiTreeWebEditor() as ed:
        if not ed.is_authed():
            raise SystemExit("Not authenticated. Run `python -m wikitree login-web`.")

        result = ed.create_profile(
            first_name=parsed.first,
            middle_name=parsed.middle,
            last_name_at_birth=parsed.last,
            gender=parsed.gender,
            birth_date=parsed.birth_date,
            birth_location=parsed.birth_location,
            death_date=parsed.death_date,
            death_location=parsed.death_location,
            bio=parsed.bio,
            sources=parsed.sources,
        )

    print(f"✓ Created: {result.get('wt_id', '?')} (user_id={result.get('user_id', '?')})")


def cmd_login_web():
    from .editor import login
    login()


def cmd_check_web():
    from .editor import WikiTreeWebEditor, WEB_SESSION_FILE, FIELD_SELECTORS
    print(f"Session file: {WEB_SESSION_FILE}")
    print(f"Exists:       {WEB_SESSION_FILE.exists()}")
    if not WEB_SESSION_FILE.exists():
        return
    with WikiTreeWebEditor() as ed:
        authed = ed.is_authed()
        print(f"Authenticated: {authed}")
    print("\nField -> selector mapping:")
    for f, s in FIELD_SELECTORS.items():
        print(f"  {f:18s} -> {s}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "login":
        cmd_login()
    elif cmd == "check":
        cmd_check()
    elif cmd == "test":
        wt_id = sys.argv[2] if len(sys.argv) > 2 else "Cauldwell-103"
        cmd_test(wt_id)
    elif cmd == "search":
        cmd_search(sys.argv[2:])
    elif cmd == "create":
        if len(sys.argv) < 3:
            raise SystemExit("Usage: python -m wikitree create FILE.json")
        cmd_create(sys.argv[2])
    elif cmd == "create-one":
        cmd_create_one(sys.argv[2:])
    elif cmd == "link":
        if len(sys.argv) < 3:
            raise SystemExit("Usage: python -m wikitree link FILE.json")
        cmd_link(sys.argv[2])
    elif cmd == "link-one":
        cmd_link_one(sys.argv[2:])
    elif cmd == "login-web":
        cmd_login_web()
    elif cmd == "check-web":
        cmd_check_web()
    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
