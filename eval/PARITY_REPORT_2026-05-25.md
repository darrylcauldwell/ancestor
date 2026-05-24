# Backend parity — python vs swift-mcp

- python source: `eval/runs/2026-05-24T19-56-44.json` (2026-05-24T19:56:44)
- swift source:  `eval/runs/2026-05-24T19-43-36.json` (2026-05-24T19:43:36)

## Headline

- both-backend measured cells:  46
- backends agree:               31 (67% of measured)
- backends disagree:            15
- only one backend measured:    0
- neither measured (unmeasurable kinds): 8

## Backend disagreements (actionable drift)

| Subject | Kind | Expected | Python | Swift |
|---|---|---|---|---|
| John Cauldwell (pair) | parent_link | supported | inconclusive | supported |
| Charles Herbert Hodgkinson | death_disambiguation | out_of_scope | inconclusive | supported |
| Catherine Hannah Bown | birth_disambiguation | inconclusive | supported | inconclusive |
| Catherine Hannah Bown | marriage_disambiguation | supported | supported | inconclusive |
| Catherine Hannah Bown | parent_link | inconclusive | inconclusive | supported |
| George Bowden | birth_disambiguation | supported_with_year_correction | supported | inconclusive |
| George Bowden | death_disambiguation | out_of_scope | inconclusive | supported |
| George Bowden | marriage_disambiguation | not_yet_verified | inconclusive | supported |
| Ernest Cauldwell | marriage_disambiguation | supported | supported | inconclusive |
| Mabel Cauldwell → Mabel Brewell (1897-1928) | parent_link | supported | inconclusive | supported |
| Stephen Sherwin | parent_link | inconclusive | inconclusive | supported |
| Elizabeth Cauldwell | birth_disambiguation | supported | supported | inconclusive |
| Elizabeth Cauldwell | death_disambiguation | supported | supported | inconclusive |
| Elizabeth Cauldwell | marriage_disambiguation | supported_via_matched_page | supported | inconclusive |
| Elizabeth Cauldwell | parent_link | supported | inconclusive | supported |

### Dispatch-log drill-down (swift backend)

**John Cauldwell (pair) / parent_link** (154 total dispatch entries)
  - `probate` Probate Calendar: John Cauldwell 1902–1906 → 0 result(s)
  - `freebmd` FreeBMD Belper births: John Cauldwell 1838–1842 → 1 result(s)
  - `freecen` FreeCen DBY 1841 census: John Cauldwell → 0 result(s)
  - `findagrave` Find a Grave Matlock Bath, Derbyshire, England burials: John Cauldwell 1902–1906 → 20 result(s)
  - `probate` Probate Calendar: John Cauldwell 1902–1906 → 0 result(s)
  - `freebmd` FreeBMD Chesterfield births: John Cauldwell 1838–1842 → 0 result(s)
  - `freecen` FreeCen DBY 1851 census: John Cauldwell → 0 result(s)
  - `familysearch` FamilySearch birth: John Cauldwell 1838–1842 [father=Caldwell, mother=Caldwell, birthPlace → 0 result(s)

**Charles Herbert Hodgkinson / death_disambiguation** (55 total dispatch entries)
  - `familysearch` FamilySearch probate: Charles Herbert Hodgkinson 1977–1981 [birthPlace=Shottle, Derbyshire → 23 result(s)
  - `familysearch` FamilySearch census: Charles Herbert Hodgkinson 1888–1979 [birthPlace=Shottle, Derbyshire, → 69 result(s)
  - `familysearch` FamilySearch burial: Charles Herbert Hodgkinson 1977–1981 [birthPlace=Shottle, Derbyshire, → 23 result(s)
  - `familysearch` FamilySearch birth: Charles Herbert Hodgkinson 1886–1890 [birthPlace=Shottle, Derbyshire,  → 43 result(s)
  - `familysearch` FamilySearch death: Charles Herbert Hodgkinson 1977–1981 [birthPlace=Shottle, Derbyshire,  → 23 result(s)
  - `familysearch` FamilySearch marriage: Charles Herbert Hodgkinson 1904–1979 [birthPlace=Shottle, Derbyshir → 22 result(s)
  - `familysearch` FamilySearch parish: Charles Herbert Hodgkinson 1888–1979 [birthPlace=Shottle, Derbyshire, → 22 result(s)
  - `freebmd` FreeBMD Belper deaths: Charles Herbert Hodgkinson 1977–1981 → 0 result(s)
  - `freebmd` FreeBMD Basford deaths: Charles Herbert Hodgkinson 1977–1981 → 0 result(s)
  - `freebmd` FreeBMD Amber Valley deaths: Charles Herbert Hodgkinson 1977–1981 → 0 result(s)
  - `freebmd` FreeBMD Derby deaths: Charles Herbert Hodgkinson 1977–1981 → 0 result(s)
  - `freebmd` FreeBMD Bakewell deaths: Charles Herbert Hodgkinson 1977–1981 → 0 result(s)

**Catherine Hannah Bown / birth_disambiguation** (73 total dispatch entries)
  - `familysearch` FamilySearch death: Catherine Hannah Ward 1905–1909 [spouse=Ward, father=Bown, mother=Kind → 97 result(s)
  - `familysearch` FamilySearch burial: Catherine Hannah Ward 1905–1909 [spouse=Ward, father=Bown, mother=Kin → 97 result(s)
  - `familysearch` FamilySearch marriage: Catherine Hannah Bown 1883–1907 [spouse=Ward, father=Bown, mother=K → 61 result(s)
  - `familysearch` FamilySearch marriage: Catherine Hannah Ward 1883–1907 [spouse=Ward, father=Bown, mother=K → 92 result(s)
  - `familysearch` FamilySearch probate: Catherine Hannah Ward 1905–1909 [spouse=Ward, father=Bown, mother=Ki → 97 result(s)
  - `familysearch` FamilySearch birth: Catherine Hannah Ward 1865–1869 [spouse=Ward, father=Bown, mother=Kind → 97 result(s)
  - `familysearch` FamilySearch census: Catherine Hannah Ward 1867–1907 [spouse=Ward, father=Bown, mother=Kin → 87 result(s)
  - `familysearch` FamilySearch parish: Catherine Hannah Ward 1867–1907 [spouse=Ward, father=Bown, mother=Kin → 91 result(s)
  - `freebmd` FreeBMD Belper births: Catherine Hannah Ward 1865–1869 → 0 result(s)
  - `freebmd` FreeBMD Chesterfield births: Catherine Hannah Ward 1865–1869 → 0 result(s)
  - `freebmd` FreeBMD Worksop births: Catherine Hannah Ward 1865–1869 → 0 result(s)
  - `freebmd` FreeBMD Amber Valley births: Catherine Hannah Ward 1865–1869 → 0 result(s)

**Catherine Hannah Bown / marriage_disambiguation** (73 total dispatch entries)
  - `freereg` FreeREG DBY marriages: Catherine Hannah Ward 1883–1907 → 0 result(s)
  - `freereg` FreeREG DBY marriages: Catherine Hannah Bown 1883–1907 → 0 result(s)
  - `freereg` FreeREG DBY marriages: Catherine Hannah Ward 1883–1907 → 0 result(s)
  - `freereg` FreeREG DBY marriages: Catherine Hannah Bown 1883–1907 → 0 result(s)
  - `familysearch` FamilySearch marriage: Catherine Hannah Bown 1883–1907 [spouse=Ward, father=Bown, mother=K → 61 result(s)
  - `freebmd` FreeBMD Belper marriages: Ward × Ward 1883–1907 → 0 result(s)
  - `familysearch` FamilySearch marriage: Catherine Hannah Ward 1883–1907 [spouse=Ward, father=Bown, mother=K → 92 result(s)
  - `freebmd` FreeBMD Basford marriages: Ward × Ward 1883–1907 → 0 result(s)
  - `freebmd` FreeBMD Worksop marriages: Ward × Ward 1883–1907 → 0 result(s)
  - `freebmd` FreeBMD Amber Valley marriages: Ward × Ward 1883–1907 → 0 result(s)
  - `freebmd` FreeBMD Derby marriages: Ward × Ward 1883–1907 → 0 result(s)
  - `freebmd` FreeBMD High Peak marriages: Ward × Ward 1883–1907 → 0 result(s)

**Catherine Hannah Bown / parent_link** (73 total dispatch entries)
  - `freereg` FreeREG DBY marriages: Catherine Hannah Ward 1883–1907 → 0 result(s)
  - `freebmd` FreeBMD Belper deaths: Catherine Hannah Ward 1905–1909 → 0 result(s)
  - `freecen` FreeCen DBY 1871 census: Catherine Hannah Ward → 0 result(s)
  - `probate` Probate Calendar: Catherine Hannah Ward 1905–1909 → 0 result(s)
  - `findagrave` Find a Grave Kirk Ireton, Derbyshire, England burials: Catherine Hannah Ward 1905–1909 → 20 result(s)
  - `freecen` FreeCen DBY 1881 census: Catherine Hannah Ward → 0 result(s)
  - `probate` Probate Calendar: Catherine Hannah Ward 1905–1909 → 0 result(s)
  - `freebmd` FreeBMD Chesterfield deaths: Catherine Hannah Ward 1905–1909 → 0 result(s)

**George Bowden / birth_disambiguation** (71 total dispatch entries)
  - `familysearch` FamilySearch burial: George Bowden 1917–1997 [spouse=Keyworth, birthPlace=Glossop, Derbysh → 44 result(s)
  - `familysearch` FamilySearch death: George Bowden 1917–1997 [spouse=Keyworth, birthPlace=Glossop, Derbyshi → 44 result(s)
  - `familysearch` FamilySearch census: George Bowden 1902–1982 [spouse=Keyworth, birthPlace=Glossop, Derbysh → 64 result(s)
  - `familysearch` FamilySearch birth: George Bowden 1900–1904 [spouse=Keyworth, birthPlace=Glossop, Derbyshi → 69 result(s)
  - `familysearch` FamilySearch marriage: George Bowden 1918–1962 [spouse=Keyworth, birthPlace=Glossop, Derby → 55 result(s)
  - `familysearch` FamilySearch parish: George Bowden 1902–1902 [spouse=Keyworth, birthPlace=Glossop, Derbysh → 48 result(s)
  - `freebmd` FreeBMD Basford births: George Bowden 1900–1904 → 0 result(s)
  - `freebmd` FreeBMD Worksop births: George Bowden 1900–1904 → 0 result(s)
  - `freebmd` FreeBMD Amber Valley births: George Bowden 1900–1904 → 0 result(s)
  - `familysearch` FamilySearch probate: George Bowden 1917–1997 [spouse=Keyworth, birthPlace=Glossop, Derbys → 38 result(s)
  - `freebmd` FreeBMD Bakewell births: George Bowden 1900–1904 → 0 result(s)
  - `freebmd` FreeBMD High Peak births: George Bowden 1900–1904 → 0 result(s)

**George Bowden / death_disambiguation** (71 total dispatch entries)
  - `freebmd` FreeBMD Belper deaths: George Bowden 1917–1997 → 0 result(s)
  - `freebmd` FreeBMD Chesterfield deaths: George Bowden 1917–1997 → 0 result(s)
  - `freebmd` FreeBMD Basford deaths: George Bowden 1917–1997 → 1 result(s)
  - `familysearch` FamilySearch death: George Bowden 1917–1997 [spouse=Keyworth, birthPlace=Glossop, Derbyshi → 44 result(s)
  - `freebmd` FreeBMD Amber Valley deaths: George Bowden 1917–1997 → 0 result(s)
  - `freebmd` FreeBMD Derby deaths: George Bowden 1917–1997 → 0 result(s)
  - `freebmd` FreeBMD High Peak deaths: George Bowden 1917–1997 → 1 result(s)
  - `freebmd` FreeBMD Ashbourne deaths: George Bowden 1917–1997 → 0 result(s)
  - `freebmd` FreeBMD Bakewell deaths: George Bowden 1917–1997 → 0 result(s)
  - `freebmd` FreeBMD Ilkeston deaths: George Bowden 1917–1997 → 1 result(s)
  - `freebmd` FreeBMD Glossop deaths: George Bowden 1917–1997 → 4 result(s)
  - `freebmd` FreeBMD South Derbyshire deaths: George Bowden 1917–1997 → 0 result(s)

**George Bowden / marriage_disambiguation** (71 total dispatch entries)
  - `familysearch` FamilySearch marriage: George Bowden 1918–1962 [spouse=Keyworth, birthPlace=Glossop, Derby → 55 result(s)
  - `freebmd` FreeBMD Belper marriages: Bowden × Keyworth 1918–1962 → 0 result(s)
  - `freebmd` FreeBMD Worksop marriages: Bowden × Keyworth 1918–1962 → 0 result(s)
  - `freebmd` FreeBMD Derby marriages: Bowden × Keyworth 1918–1962 → 0 result(s)
  - `freebmd` FreeBMD South Derbyshire marriages: Bowden × Keyworth 1918–1962 → 0 result(s)
  - `freebmd` FreeBMD Chesterfield marriages: Bowden × Keyworth 1918–1962 → 0 result(s)
  - `freebmd` FreeBMD Basford marriages: Bowden × Keyworth 1918–1962 → 0 result(s)
  - `freebmd` FreeBMD Ashbourne marriages: Bowden × Keyworth 1918–1962 → 0 result(s)
  - `freebmd` FreeBMD Glossop marriages: Bowden × Keyworth 1918–1962 → 0 result(s)
  - `freebmd` FreeBMD Amber Valley marriages: Bowden × Keyworth 1918–1962 → 0 result(s)
  - `freebmd` FreeBMD Bakewell marriages: Bowden × Keyworth 1918–1962 → 1 result(s)
  - `freebmd` FreeBMD High Peak marriages: Bowden × Keyworth 1918–1962 → 0 result(s)

**Ernest Cauldwell / marriage_disambiguation** (125 total dispatch entries)
  - `familysearch` FamilySearch marriage: Ernest Cauldwell 1903–1959 [spouse=Cauldwell, father=Cauldwell, mot → 127 result(s)
  - `freebmd` FreeBMD Belper marriages: Cauldwell × Cauldwell 1903–1959 → 0 result(s)
  - `freebmd` FreeBMD Chesterfield marriages: Cauldwell × Cauldwell 1903–1959 → 0 result(s)
  - `freebmd` FreeBMD Basford marriages: Cauldwell × Cauldwell 1903–1959 → 0 result(s)
  - `freebmd` FreeBMD Amber Valley marriages: Cauldwell × Cauldwell 1903–1959 → 0 result(s)
  - `freebmd` FreeBMD Derby marriages: Cauldwell × Cauldwell 1903–1959 → 0 result(s)
  - `freebmd` FreeBMD Ilkeston marriages: Cauldwell × Cauldwell 1903–1959 → 0 result(s)
  - `freebmd` FreeBMD High Peak marriages: Cauldwell × Cauldwell 1903–1959 → 0 result(s)
  - `freebmd` FreeBMD Ashbourne marriages: Cauldwell × Cauldwell 1903–1959 → 0 result(s)
  - `freebmd` FreeBMD South Derbyshire marriages: Cauldwell × Cauldwell 1903–1959 → 0 result(s)
  - `freebmd` FreeBMD Bakewell marriages: Cauldwell × Cauldwell 1903–1959 → 0 result(s)
  - `freebmd` FreeBMD Worksop marriages: Cauldwell × Cauldwell 1903–1959 → 0 result(s)

**Mabel Cauldwell → Mabel Brewell (1897-1928) / parent_link** (380 total dispatch entries)
  - `freecen` FreeCen DBY 1901 census: Mabel Cauldwell → 0 result(s)
  - `freebmd` FreeBMD Belper births: Mabel Cauldwell 1895–1899 → 1 result(s)
  - `findagrave` Find a Grave Belper, Derbyshire, England burials: Mabel Cauldwell 1926–1930 → 1 result(s)
  - `probate` Probate Calendar: Mabel Cauldwell 1926–1930 → 0 result(s)
  - `freereg` FreeREG DBY parish records: Mabel Cauldwell 1897–1928 → 0 result(s)
  - `probate` Probate Calendar: Mabel Cauldwell 1926–1930 → 0 result(s)
  - `freebmd` FreeBMD Chesterfield births: Mabel Cauldwell 1895–1899 → 0 result(s)
  - `freecen` FreeCen DBY 1911 census: Mabel Cauldwell → 0 result(s)

**Stephen Sherwin / parent_link** (56 total dispatch entries)
  - `freecen` FreeCen DBY 1841 census: Stephen Sherwin → 0 result(s)
  - `freebmd` FreeBMD Belper deaths: Stephen Sherwin 1856–1860 → 0 result(s)
  - `probate` Probate Calendar: Stephen Sherwin 1856–1860 → 0 result(s)
  - `findagrave` Find a Grave Brassington, Derbyshire, England burials: Stephen Sherwin 1856–1860 → 15 result(s)
  - `probate` Probate Calendar: Stephen Sherwin 1856–1860 → 0 result(s)
  - `freereg` FreeREG DBY parish records: Stephen Sherwin 1774–1858 → 0 result(s)
  - `freebmd` FreeBMD Chesterfield deaths: Stephen Sherwin 1856–1860 → 0 result(s)
  - `freecen` FreeCen DBY 1851 census: Stephen Sherwin → 0 result(s)

**Elizabeth Cauldwell / birth_disambiguation** (86 total dispatch entries)
  - `freebmd` FreeBMD Belper births: Elizabeth Beighton 1842–1846 → 0 result(s)
  - `freebmd` FreeBMD Chesterfield births: Elizabeth Beighton 1842–1846 → 0 result(s)
  - `familysearch` FamilySearch birth: Elizabeth Beighton 1842–1846 [father=Caldwell, mother=Caldwell, birthP → 18 result(s)
  - `freebmd` FreeBMD Basford births: Elizabeth Beighton 1842–1846 → 0 result(s)
  - `freebmd` FreeBMD Worksop births: Elizabeth Beighton 1842–1846 → 0 result(s)
  - `freebmd` FreeBMD Amber Valley births: Elizabeth Beighton 1842–1846 → 0 result(s)
  - `familysearch` FamilySearch marriage: Elizabeth Beighton 1860–1906 [father=Caldwell, mother=Caldwell, bir → 6 result(s)
  - `freebmd` FreeBMD Derby births: Elizabeth Beighton 1842–1846 → 0 result(s)
  - `freebmd` FreeBMD Bakewell births: Elizabeth Beighton 1842–1846 → 0 result(s)
  - `familysearch` FamilySearch marriage: Elizabeth Caldwell 1860–1906 [father=Caldwell, mother=Caldwell, bir → 95 result(s)
  - `familysearch` FamilySearch death: Elizabeth Beighton 1904–1908 [father=Caldwell, mother=Caldwell, birthP → 0 result(s)
  - `freebmd` FreeBMD Ilkeston births: Elizabeth Beighton 1842–1846 → 0 result(s)

**Elizabeth Cauldwell / death_disambiguation** (86 total dispatch entries)
  - `familysearch` FamilySearch birth: Elizabeth Beighton 1842–1846 [father=Caldwell, mother=Caldwell, birthP → 18 result(s)
  - `familysearch` FamilySearch marriage: Elizabeth Beighton 1860–1906 [father=Caldwell, mother=Caldwell, bir → 6 result(s)
  - `familysearch` FamilySearch marriage: Elizabeth Caldwell 1860–1906 [father=Caldwell, mother=Caldwell, bir → 95 result(s)
  - `familysearch` FamilySearch death: Elizabeth Beighton 1904–1908 [father=Caldwell, mother=Caldwell, birthP → 0 result(s)
  - `familysearch` FamilySearch burial: Elizabeth Beighton 1904–1908 [father=Caldwell, mother=Caldwell, birth → 0 result(s)
  - `familysearch` FamilySearch census: Elizabeth Beighton 1844–1906 [father=Caldwell, mother=Caldwell, birth → 87 result(s)
  - `familysearch` FamilySearch death: Elizabeth Beighton 1904–1908 [father=Caldwell, mother=Caldwell, birthP → 0 result(s)
  - `familysearch` FamilySearch burial: Elizabeth Beighton 1904–1908 [father=Caldwell, mother=Caldwell, birth → 0 result(s)
  - `familysearch` FamilySearch probate: Elizabeth Beighton 1904–1908 [father=Caldwell, mother=Caldwell, birt → 0 result(s)
  - `familysearch` FamilySearch parish: Elizabeth Beighton 1844–1906 [father=Caldwell, mother=Caldwell, birth → 36 result(s)
  - `familysearch` FamilySearch probate: Elizabeth Beighton 1904–1908 [father=Caldwell, mother=Caldwell, birt → 0 result(s)
  - `freebmd` FreeBMD Belper deaths: Elizabeth Beighton 1904–1908 → 0 result(s)

**Elizabeth Cauldwell / marriage_disambiguation** (86 total dispatch entries)
  - `freereg` FreeREG DBY marriages: Elizabeth Beighton 1860–1906 → 0 result(s)
  - `freereg` FreeREG DBY marriages: Elizabeth Caldwell 1860–1906 → 0 result(s)
  - `familysearch` FamilySearch marriage: Elizabeth Beighton 1860–1906 [father=Caldwell, mother=Caldwell, bir → 6 result(s)
  - `freereg` FreeREG DBY marriages: Elizabeth Caldwell 1860–1906 → 0 result(s)
  - `familysearch` FamilySearch marriage: Elizabeth Caldwell 1860–1906 [father=Caldwell, mother=Caldwell, bir → 95 result(s)
  - `freereg` FreeREG DBY marriages: Elizabeth Beighton 1860–1906 → 0 result(s)
  - `freebmd` FreeBMD Chesterfield marriages: Elizabeth Beighton 1860–1906 → 0 result(s)
  - `freebmd` FreeBMD Worksop marriages: Elizabeth Beighton 1860–1906 → 0 result(s)
  - `freebmd` FreeBMD Derby marriages: Elizabeth Beighton 1860–1906 → 0 result(s)
  - `freebmd` FreeBMD High Peak marriages: Elizabeth Beighton 1860–1906 → 0 result(s)
  - `freebmd` FreeBMD Amber Valley marriages: Elizabeth Beighton 1860–1906 → 0 result(s)
  - `freebmd` FreeBMD Ilkeston marriages: Elizabeth Beighton 1860–1906 → 0 result(s)

**Elizabeth Cauldwell / parent_link** (86 total dispatch entries)
  - `freecen` FreeCen DBY 1851 census: Elizabeth Beighton → 0 result(s)
  - `findagrave` Find a Grave Risca, Monmouthshire, Wales burials: Elizabeth Beighton 1904–1908 → 20 result(s)
  - `probate` Probate Calendar: Elizabeth Beighton 1904–1908 → 0 result(s)
  - `probate` Probate Calendar: Elizabeth Beighton 1904–1908 → 0 result(s)
  - `freebmd` FreeBMD Belper births: Elizabeth Beighton 1842–1846 → 0 result(s)
  - `freereg` FreeREG DBY marriages: Elizabeth Beighton 1860–1906 → 0 result(s)
  - `freebmd` FreeBMD Chesterfield births: Elizabeth Beighton 1842–1846 → 0 result(s)
  - `familysearch` FamilySearch birth: Elizabeth Beighton 1842–1846 [father=Caldwell, mother=Caldwell, birthP → 18 result(s)

## Full per-(subject, kind) matrix

| Subject | Kind | Expected | Python | Swift | State |
|---|---|---|---|---|---|
| Sarah Jane Byard | birth_disambiguation | out_of_scope | supported | supported | agree |
| Sarah Jane Byard | death_disambiguation | inconclusive | inconclusive | inconclusive | agree |
| Sarah Jane Byard | marriage_disambiguation | inconclusive | inconclusive | inconclusive | agree |
| Sarah Jane Byard | parent_link | inconclusive | inconclusive | inconclusive | agree |
| John Cauldwell (pair) | identity_disambiguation | supported | supported | supported | agree |
| John Cauldwell (pair) | parent_link | supported | inconclusive | supported | disagree |
| Charles Herbert Hodgkinson | birth_disambiguation | out_of_scope | supported | supported | agree |
| Charles Herbert Hodgkinson | death_disambiguation | out_of_scope | inconclusive | supported | disagree |
| Charles Herbert Hodgkinson | marriage_disambiguation | inconclusive | supported | supported | agree |
| Charles Herbert Hodgkinson | parent_link | inconclusive | inconclusive | inconclusive | agree |
| Lily Margaret Cauldwell | any_other_kind | inconclusive | — | — | both_unmeasured |
| Lily Margaret Cauldwell | birth_disambiguation | inconclusive | inconclusive | inconclusive | agree |
| Catherine Hannah Bown | birth_disambiguation | inconclusive | supported | inconclusive | disagree |
| Catherine Hannah Bown | death_disambiguation | supported | supported | supported | agree |
| Catherine Hannah Bown | marriage_disambiguation | supported | supported | inconclusive | disagree |
| Catherine Hannah Bown | parent_link | inconclusive | inconclusive | supported | disagree |
| Catherine Hannah Bown | surname_pivot | supported | — | — | both_unmeasured |
| George Bowden | birth_disambiguation | supported_with_year_correction | supported | inconclusive | disagree |
| George Bowden | death_disambiguation | out_of_scope | inconclusive | supported | disagree |
| George Bowden | geographic_outlier_handling | supported | — | — | both_unmeasured |
| George Bowden | marriage_disambiguation | not_yet_verified | inconclusive | supported | disagree |
| George Bowden | parent_link | out_of_scope | inconclusive | inconclusive | agree |
| Robert Cauldwell | birth_disambiguation | supported | supported | supported | agree |
| Robert Cauldwell | death_disambiguation | supported | supported | supported | agree |
| Robert Cauldwell | marriage_disambiguation | supported | supported | supported | agree |
| Robert Cauldwell | military_service | supported | supported | supported | agree |
| Robert Cauldwell | parent_link | supported | supported | supported | agree |
| Robert Cauldwell | spouse_disambiguation | supported | supported | supported | agree |
| Ernest Cauldwell | birth_disambiguation | supported | supported | supported | agree |
| Ernest Cauldwell | death_disambiguation | supported | supported | supported | agree |
| Ernest Cauldwell | marriage_disambiguation | supported | supported | inconclusive | disagree |
| Ernest Cauldwell | parent_link | supported | supported | supported | agree |
| Ernest Cauldwell | spouse_disambiguation | supported | supported | supported | agree |
| Mabel Cauldwell → Mabel Brewell (1897-1928) | identity_disambiguation.cluster_a | supported | — | — | both_unmeasured |
| Mabel Cauldwell → Mabel Brewell (1897-1928) | identity_disambiguation.cluster_b | contradicted | — | — | both_unmeasured |
| Mabel Cauldwell → Mabel Brewell (1897-1928) | marriage_disambiguation | supported | supported | supported | agree |
| Mabel Cauldwell → Mabel Brewell (1897-1928) | parent_link | supported | inconclusive | supported | disagree |
| Lydia Kenworthy | birth_disambiguation | supported_with_geographic_discrepancy | inconclusive | inconclusive | agree |
| Lydia Kenworthy | cross_county_handling | supported | — | — | both_unmeasured |
| Lydia Kenworthy | death_disambiguation | supported | supported | supported | agree |
| Lydia Kenworthy | marriage_disambiguation | supported | inconclusive | inconclusive | agree |
| Lydia Kenworthy | parent_link | out_of_scope | inconclusive | inconclusive | agree |
| Lydia Kenworthy | surname_pivot | supported | — | — | both_unmeasured |
| Stephen Sherwin | baptism_disambiguation | inconclusive | inconclusive | inconclusive | agree |
| Stephen Sherwin | burial_disambiguation | supported | inconclusive | inconclusive | agree |
| Stephen Sherwin | marriage_disambiguation | supported | inconclusive | inconclusive | agree |
| Stephen Sherwin | parent_link | inconclusive | inconclusive | supported | disagree |
| Stephen Sherwin | spouse_disambiguation | supported | supported | supported | agree |
| Elizabeth Cauldwell | birth_disambiguation | supported | supported | inconclusive | disagree |
| Elizabeth Cauldwell | cross_county_handling | supported | — | — | both_unmeasured |
| Elizabeth Cauldwell | death_disambiguation | supported | supported | inconclusive | disagree |
| Elizabeth Cauldwell | marriage_disambiguation | supported_via_matched_page | supported | inconclusive | disagree |
| Elizabeth Cauldwell | parent_link | supported | inconclusive | supported | disagree |
| Elizabeth Cauldwell | spouse_disambiguation | supported_via_matched_page | inconclusive | inconclusive | agree |
