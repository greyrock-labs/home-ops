# codswallop drive inventory — `tank`

Host: `codswallop` (TrueNAS SCALE), Supermicro SC846 chassis, 24 front hot-swap
bays wired 6 rows x 4 columns. Physical position was read off each drive by
pulling it and reading the serial; the OS only auto-resolved 16 of 24 bays
via sysfs (`sesutil` isn't installed on this box), so the rest were confirmed
by hand.

Scope: **`tank` only** (2x 12-wide raidz3, all 24 bays). `drone` (4x Intel SSD
raidz1) and `boot-pool` (2x NVMe mirror) live on internal enclosures, not
this front backplane — not inventoried here yet.

Recorded 2026-07-14.

| Position | Device | Serial   | Model                 | Vdev     | ZFS GUID             | Partition UUID                       |
|----------|--------|----------|-----------------------|----------|----------------------|--------------------------------------|
| 1,1      | sdq    | 6AGDBBDS | WDC WD142KFGX-68AFPN0 | raidz3-1 | 5162615688432952545  | d7c73976-d026-402e-97c5-f18829d95ac5 |
| 1,2      | sdr    | 9LK5GHUG | WDC WD140EFGX-68B0GN0 | raidz3-1 | 9528986425796206229  | 5a039922-43fb-436c-8ad2-71d294bdd6bb |
| 1,3      | sds    | 6AGB6RPU | WDC WD142KFGX-68AFPN0 | raidz3-1 | 15905671514926340770 | 12e0575a-7504-4576-9fac-68f80625a9d8 |
| 1,4      | sdt    | 9LK8EP0G | WDC WD140EFGX-68B0GN0 | raidz3-1 | 17250043149489576665 | e529d12f-49de-4717-9c4a-e9700bfcb697 |
| 2,1      | sdu    | 9LKLU6HG | WDC WD140EFGX-68B0GN0 | raidz3-1 | 11387212443691640167 | 3cf2ba41-201e-48ab-bb6e-b19b7bab1682 |
| 2,2      | sdv    | 9MJ914SU | WDC WD140EFGX-68B0GN0 | raidz3-1 | 16522563479827833131 | 428cd886-b33f-4ecf-8cbd-5397eddda0eb |
| 2,3      | sdw    | 9MJ918XU | WDC WD140EFGX-68B0GN0 | raidz3-1 | 11353330790961211453 | 37012fdb-4531-47dd-ab20-133c76f2eb3c |
| 2,4      | sdx    | 9LHZ4GAG | WDC WD140EFGX-68B0GN0 | raidz3-1 | 5296665786233597708  | fa8dc73a-7ec7-4017-bc7c-f3d5f0aa310e |
| 3,1      | sdy    | PLG1TMRP | WDC WD142KFGX-68CLHN0 | raidz3-1 | 6253536332998937008  | 6865dcb7-98fb-4269-bf39-3a2c0b1458ec |
| 3,2      | sdz    | 9LKTEV9G | WDC WD140EFGX-68B0GN0 | raidz3-1 | 6561326338586955311  | 2f833b0c-1fd1-43dd-8313-5ca93696818a |
| 3,3      | sdaa   | 6AGDBHTS | WDC WD142KFGX-68AFPN0 | raidz3-1 | 15796717330663993579 | 19f514f2-79c2-4f22-9d0a-c0f59e860045 |
| 3,4      | sdab   | 6AGD4P2S | WDC WD142KFGX-68AFPN0 | raidz3-1 | 3575075254959833515  | 0fee9394-7e3f-478a-9cc0-a262ba2fb3b6 |
| 4,1      | sdf    | 6AGDBWVS | WDC WD142KFGX-68AFPN0 | raidz3-0 | 7279227783266938190  | 8fac89d1-f619-4b49-a186-6dbcb4193b39 |
| 4,2      | sde    | 9LK8HS5G | WDC WD140EFGX-68B0GN0 | raidz3-0 | 2790247225639904021  | eb36f679-44d0-47c9-936a-7f0823a93a06 |
| 4,3      | sdj    | 6AGD42AS | WDC WD142KFGX-68AFPN0 | raidz3-0 | 8561160802317281249  | 704940ca-4a94-4686-b0ad-22a455821d88 |
| 4,4      | sdk    | ZTM0D5KT | ST14000NE0008-2JK101  | raidz3-0 | 1373118605235796625  | 4233d5e5-8621-4546-9b81-cdf3b85a7deb |
| 5,1      | sdd    | PLG1UTSP | WDC WD142KFGX-68CLHN0 | raidz3-0 | 18214958049010716377 | fa5ce3f0-7cba-48a5-a60f-5736407ea901 |
| 5,2      | sdb    | PLG1TSKP | WDC WD142KFGX-68CLHN0 | raidz3-0 | 7644125228107865196  | 3cfcc4bb-fed3-4750-b39e-07ad4692145f |
| 5,3      | sdg    | PLG1LVBP | WDC WD142KFGX-68CLHN0 | raidz3-0 | 7273252243872584608  | bd186a9a-7593-4b0b-9fec-55bfdd1eb22a |
| 5,4      | sdl    | 9MHV93NU | WDC WD140EFGX-68B0GN0 | raidz3-0 | 6333609613364432246  | fc98786c-55af-4455-97ba-3ed544630096 |
| 6,1      | sdc    | QGKAHABT | WDC WD140EFGX-68B0GN0 | raidz3-0 | 12506996590400224400 | dbe3b781-e8ba-4fa2-b7fa-de618c98a28e |
| 6,2      | sda    | 9KG6W51L | WUH721414ALE601       | raidz3-0 | 11048458018417045731 | fcfd35f3-fab2-4255-976e-07eaf3f84825 |
| 6,3      | sdh    | 9JHBWSDT | WUH721414ALE601       | raidz3-0 | 16491632110637475743 | 82d28bf7-849a-48d9-8770-b6c81d9a4cd7 |
| 6,4      | sdi    | 9KGU7W8L | WUH721414ALE601       | raidz3-0 | 12278606832133043911 | 7a380586-67e6-4912-b24a-57defd713e99 |

## How this was built

1. `zpool status` and `zpool status -g tank` — same tree, walked in the same
   order, so the partition-UUID leaf names in the first pair positionally
   with the numeric ZFS GUID in the second.
2. `lsblk -o NAME,SERIAL,SIZE,MODEL,PARTUUID` — joins partition UUID to
   device node and serial.
3. Physical (row, column) position was read by hand off each drive, keyed on
   the last 4 characters of its serial (confirmed unique across all 24
   drives in `tank`).
