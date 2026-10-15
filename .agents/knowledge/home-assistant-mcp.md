# Home Assistant MCP access

Home Assistant is reached through the community **ha-mcp** add-on (HACS), not HA's
built-in "Model Context Protocol Server" integration. The built-in server only exposes
the Assist API: it has no config or dashboard tools, so it cannot read or write the
automations and dashboard in `docs/homeassistant/ha-config/`.

- The ha-mcp URL embeds a secret. Never print it, echo it, or commit it.
- It is registered as a local-scope MCP server for the home-ops project, so its `ha_*`
  tools are available in sessions started in this repo. A session that was already
  running when it was added needs `/mcp` or a restart to see it.
- `ha_config_set_dashboard` and `ha_config_set_automation` require a `BestPracticeKey`.
  It is printed at the top of `ha_get_skill_guide()`; get it right before the write. The
  key rotates hourly, so a key from earlier in the session may be rejected.

Export and restore of the snapshot is in `docs/homeassistant/ha-config/README.md`.
