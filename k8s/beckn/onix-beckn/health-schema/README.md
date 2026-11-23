# Health referral schemas for the onix adapters

The health-referral flow (`select` / `init` / `confirm` / `status` with an `hrf:HealthReferral` contract, as
Spice sends it) carries `@context` addresses on `schema.beckn.io`. That host now redirects to
`schema.nfh.global`, which answers 404, so an adapter that fetches them refuses the message
("failed to load schema from https://schema.beckn.io/HealthParticipant/v2.1/attributes.yaml").

These copies are loaded at start (`extendedSchema_localSchemaPath`) by OpenMRS's Beckn adapter pair, `onix-bap` /
`onix-bpp` — the referral flow stays on standard Beckn. (OpenMRS's Sygnal adapter, `onix-sygnal`, does not load these schemas: it holds the Sygnal profile only.)
`beckn-deploy.sh openmrs` puts them in the ConfigMap `onix-schema` next to the CCE schemas. An adapter looks a schema up by its folder name
(`<Schema>/attributes.yaml`; the version folder is dropped), so the `@context` address of a message only has
to end in the same `<Schema>/<version>/...`.

| Folder | Source |
|---|---|
| `Health*`, `Service*`, `Credential` | `beckn/DHP-Specs`, `devkit/config/schema/`, commit `7a117e4` (the `Service*` base files there have no version folder; they are placed under `v2.1/`, the version the Health files reference) |
| `CodedValue`, `Document` | `beckn/schemas`, `schema/`, `main` (referenced by the Health files, missing from DHP-Specs) |
| `stub/v1` | `beckn/DHP-Specs`, `devkit/stub/attributes.yaml` (the `@context` of coded values such as `ServiceCategory`) |

Only `attributes.yaml` is kept: the adapters validate against it and never read `context.jsonld`.
To update, copy the new `attributes.yaml` files over these and redeploy (`install-beckn.sh --only openmrs`).
