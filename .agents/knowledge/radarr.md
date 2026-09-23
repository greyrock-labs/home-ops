# Radarr

## `Remux + WEB 2160p` is an allowlist

The profile requires a release group recognised by TRaSH: the remux / UHD Bluray / WEB
tier formats (scores 1600–1950) are assigned and `min_format_score` is `1`. Anything
without a tiered group scores 0 and is rejected, including the ~10% of releases with no
parseable group; those are searched for manually. Penalty formats stay alongside, so a
tiered release carrying a German track still nets negative.

This replaced blocklisting individual multi-audio groups, which was whack-a-mole. The
tiers are maintained upstream.

`upgrade.until_score` is 0 on purpose, so files already on disk count as satisfied.
Raising it would re-grab the whole library.

## Indexer language metadata

Language custom formats are `LanguageSpecification`, so they only fire when the indexer
populates languages. Measured on identical releases:

| Indexer | Full language list |
| --- | --- |
| NZBgeek | 5/5 |
| Nzb.life | 1/4 |
| DrunkenSlug | 0/4 |
| NinjaCentral | 0/2 |
| DOGnzb | 0/2 |

Raising NZBgeek's priority in Prowlarr does not help: Radarr accepts or rejects each
listing before ranking, so priority only orders listings that already passed. Only
indexer-independent signals work (release group, release title). Radarr has no
indexer-based custom format spec; the full list is Edition, IndexerFlag, Language,
QualityModifier, ReleaseGroup, ReleaseTitle, Resolution, Size, Source, Year. `Unknown`
is a distinct language from `English`.
