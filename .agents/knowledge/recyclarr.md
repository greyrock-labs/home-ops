# Recyclarr

## Custom formats defined in this repo

`custom_formats` only accepts `trash_ids`, so an in-repo format needs a local resource
provider in `settings.yml`:

```yaml
resource_providers:
  - name: local-custom-formats
    type: custom-formats
    service: radarr
    path: /config/custom-formats
```

- `settings.yml` lives in `RECYCLARR_CONFIG_DIR` (`/config` in the image).
  `RECYCLARR_DATA_DIR` (`/tmp` here) is only logs and the guide clone.
- Every `*.json` under the provider `path` is loaded recursively.
- The last provider wins per trash_id, so reusing a TRaSH id overrides that format.
- Omitting `score` under `assign_scores_to` applies the guide's `trash_scores.default`.

In home-ops this is a second ConfigMap in `kustomization.yaml` plus mounts in the
HelmRelease. Example: `kubernetes/apps/downloads/recyclarr/app/config/custom-formats/multi-audio-groups.json`.

## Verifying a sync

The cronjob sets `successfulJobsHistory: 0`, so a manual job is deleted as soon as it
completes and its logs are gone. Check Flux has synced the ConfigMap first
(`kubectl -n downloads get cm recyclarr -o jsonpath='{.data.recyclarr\.yml}'`), run
`kubectl -n downloads create job --from=cronjob/recyclarr <name>`, wait with
`kubectl -n downloads wait --for=condition=complete`, then verify against Radarr:
`/api/v3/qualityprofile/<id>` for scores and `/api/v3/customformat` for specs.
