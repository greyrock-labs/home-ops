# codswallop drive inventory — `tank`

Host: `codswallop` (TrueNAS SCALE), Supermicro SC846 chassis, 24 front hot-swap
bays wired 6 rows x 4 columns. Physical position was read off each drive by
pulling it and reading the serial; the OS only auto-resolved 16 of 24 bays
via sysfs (`sesutil` isn't installed on this box), so the rest were confirmed
by hand.

Scope: **`tank` only** (2x 12-wide raidz2, all 24 bays). `drone` (4x Intel SSD
raidz1) and `boot-pool` (1x NVMe, single disk) live on internal enclosures,
not this front backplane — not inventoried here yet.

Recorded 2026-09-15.

| Position | Device | Serial   | Model                 | Vdev     | ZFS GUID             | Partition UUID                       |
|----------|--------|----------|-----------------------|----------|----------------------|--------------------------------------|
| 1,1      | sdi    | 6AGDBBDS | WDC WD142KFGX-68AFPN0 | raidz2-0 | 11573725303957118005 | a5cf8548-cfb8-41ec-a9a5-0e0e6c3c6a5c |
| 1,2      | sdb    | 9LK5GHUG | WDC WD140EFGX-68B0GN0 | raidz2-0 | 15302533131966421756 | 273c1402-c81b-4b6a-93e2-94fb98b6b46f |
| 1,3      | sdp    | 6AGB6RPU | WDC WD142KFGX-68AFPN0 | raidz2-0 | 15252783339504975017 | 2ed988b6-6100-48e4-86ca-b844b484658a |
| 1,4      | sdr    | 9LK8EP0G | WDC WD140EFGX-68B0GN0 | raidz2-0 | 5965305877860834517  | cdb9e14d-2c48-4bdc-baad-9c8bcd34fe45 |
| 2,1      | sdg    | 9LKLU6HG | WDC WD140EFGX-68B0GN0 | raidz2-0 | 3252754355801828365  | c750ca3d-abc7-48fe-ba30-b3ac6865cb64 |
| 2,2      | sdd    | 9MJ914SU | WDC WD140EFGX-68B0GN0 | raidz2-0 | 13870048604698521727 | 9cf91805-4b86-4b02-a8c9-bdbb7e7ff5fc |
| 2,3      | sda    | 9MJ918XU | WDC WD140EFGX-68B0GN0 | raidz2-0 | 11869712381185075245 | 8f0e0698-8ec5-4d8d-8ae1-ccbfa2dd9cf5 |
| 2,4      | sdk    | 9LHZ4GAG | WDC WD140EFGX-68B0GN0 | raidz2-0 | 5974922910722647439  | 68a31fe4-9a90-492c-814b-955b78023ceb |
| 3,1      | sdu    | PLG1TMRP | WDC WD142KFGX-68CLHN0 | raidz2-0 | 12751548228389663964 | ce15fee5-06b9-4123-81e3-7efef320546c |
| 3,2      | sde    | 9LKTEV9G | WDC WD140EFGX-68B0GN0 | raidz2-0 | 13009132313636805983 | 6ba28acd-cb8c-4c36-bec5-bb3844151970 |
| 3,3      | sdo    | 6AGDBHTS | WDC WD142KFGX-68AFPN0 | raidz2-0 | 4411833743416322512  | 4ced15da-1548-4507-995a-a454ec91c47b |
| 3,4      | sdn    | 6AGD4P2S | WDC WD142KFGX-68AFPN0 | raidz2-0 | 3361414942688335505  | 5ded8128-beaa-4dd4-bfc4-7175e551315b |
| 4,1      | sdv    | 6AGDBWVS | WDC WD142KFGX-68AFPN0 | raidz2-1 | 17439994999811862571 | cc115509-653c-408f-b6cf-d27ec668a94c |
| 4,2      | sdc    | 9LK8HS5G | WDC WD140EFGX-68B0GN0 | raidz2-1 | 8628572730111718233  | 2db4ba89-7b85-427b-90f4-ddeb2d744475 |
| 4,3      | sdq    | 6AGD42AS | WDC WD142KFGX-68AFPN0 | raidz2-1 | 12715093042916516245 | b0199de5-8c8f-4038-84e5-e65ab36ea37e |
| 4,4      | sdm    | ZTM0D5KT | ST14000NE0008-2JK101  | raidz2-1 | 9449097917545363331  | 6addf02b-3c77-4c50-8a7d-b4e363cfcddf |
| 5,1      | sdx    | PLG1UTSP | WDC WD142KFGX-68CLHN0 | raidz2-1 | 11667562915456248080 | c5c23879-8f4c-4adb-8303-f02cbf79e4d6 |
| 5,2      | sdf    | PLG1TSKP | WDC WD142KFGX-68CLHN0 | raidz2-1 | 1136047250647759730  | 77f2ac00-98ee-4239-84e8-39e687865cfc |
| 5,3      | sdt    | PLG1LVBP | WDC WD142KFGX-68CLHN0 | raidz2-1 | 13666632890011672468 | bbf43d36-4982-453d-bf58-3536e0974f0e |
| 5,4      | sdj    | 9MHV93NU | WDC WD140EFGX-68B0GN0 | raidz2-1 | 14678972897263928436 | 9ac4dcc7-45b2-4427-83d2-b00a94544839 |
| 6,1      | sdw    | QGKAHABT | WDC WD140EFGX-68B0GN0 | raidz2-1 | 605610797044666230   | ba0e86fa-8982-4bb9-a3de-3a71a8fdf034 |
| 6,2      | sdh    | 9KG6W51L | WUH721414ALE601       | raidz2-1 | 3222350650259822650  | 95ee36e9-d765-4360-ae09-b3cce0bd33d6 |
| 6,3      | sds    | 9JHBWSDT | WUH721414ALE601       | raidz2-1 | 1921930286618653090  | 138de46b-a29d-466d-bb50-f86feec349d3 |
| 6,4      | sdl    | 9KGU7W8L | WUH721414ALE601       | raidz2-1 | 1851352836767153139  | 12cc557c-fc79-4e9f-8c1a-6690da30a5c6 |

## How this was built

1. `zpool status` and `zpool status -g tank` — same tree, walked in the same
   order, so the partition-UUID leaf names in the first pair positionally
   with the numeric ZFS GUID in the second.
2. `lsblk -o NAME,SERIAL,SIZE,MODEL,PARTUUID` — joins partition UUID to
   device node and serial.
3. Physical (row, column) position was read by hand off each drive, keyed on
   the last 4 characters of its serial (confirmed unique across all 24
   drives in `tank`).
