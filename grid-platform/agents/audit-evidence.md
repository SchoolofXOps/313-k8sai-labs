# Audit evidence

Read from the grid-sandbox API server's audit log (Metadata level), ConfigMaps in agent-target, non-read verbs only.

| Who | Verb | Object | Code | What it proves |
|---|---|---|---|---|
| `kubernetes-admin` | patch | configmaps/target-settings | 200 | the applied change is attributed to the human who approved it |
| `kubernetes-admin` | create | configmaps/target-settings | 201 | the human created the tenant setting |
| `system:serviceaccount:agent-mcp:mcp-reader` | create | configmaps/(none: refused before the body was read) | 403 | the tool server identity cannot write, whatever its tools offer |
| `system:serviceaccount:agent-actor:actor` | patch | configmaps/target-settings | 403 | the actor could not change the tenant setting directly |
