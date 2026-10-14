# Home Assistant MCP access

Home Assistant is reached through the community **ha-mcp** add-on (HACS), not HA's
built-in "Model Context Protocol Server" integration. The built-in server only exposes
the Assist API: it has no config or dashboard tools, so it cannot read or write the
automations and dashboard in `docs/homeassistant/ha-config/`.

- The ha-mcp URL embeds a secret. Never print it, echo it, or commit it.
- It is registered only as a local-scope MCP server in the
  `~/src/greyrock-labs/homeassistant` project directory, so its `ha_*` tools are not
  available from a session started in home-ops.
- `ha_config_set_dashboard` requires a `BestPracticeKey`. Get it from
  `ha_get_skill_guide(file='references/dashboard-guide.md')` right before the write;
  the key rotates hourly, so a key from earlier in the session may be rejected.

Export and restore of the snapshot is in `docs/homeassistant/ha-config/README.md`.
