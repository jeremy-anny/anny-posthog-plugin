# PostHog Plugin (anny)

Spiegel von [`PostHog/ai-plugin`](https://github.com/PostHog/ai-plugin), umgebogen
auf unser selbst gehostetes PostHog unter **https://posthog.anny.cloud**.

Identisch zum offiziellen Plugin — ~160 Skills, Slash-Commands, `error-analyzer`,
LLM-Analytics-Hook — nur zeigt der MCP-Connector auf `mcp.anny.cloud` statt auf
`mcp.posthog.com`, und der Login läuft gegen unsere Instanz.

Anmeldung passiert per **OAuth mit Dynamic Client Registration**: niemand trägt
irgendwo einen API-Key ein. Beim ersten Tool-Aufruf registriert sich Claude
selbst als OAuth-Client bei `posthog.anny.cloud`, der User klickt einmal
„Authorize", fertig. Die Rechte sind danach die des PostHog-Accounts — wer dort
kein Konto hat, kommt auch über das Plugin nicht rein.

---

## Für Nutzer: installieren

### Claude App (Web, Desktop-Chat, Cowork)

1. **Customize** in der linken Sidebar → Tab **Plugins**
2. Unter **Personal plugins** auf **+** → **Add marketplace**
3. `jeremy-anny/anny-posthog-plugin` eintragen → **Sync**
4. **Browse** → **PostHog (anny)** → **Install**
5. Beim ersten PostHog-Befehl öffnet sich der Login auf `posthog.anny.cloud` →
   **Authorize**

Hooks und Sub-Agents (`error-analyzer`, das Session-Capture) laufen nur in
Cowork — in der normalen Chat-Ansicht sind sie ausgegraut. Skills und der
MCP-Connector funktionieren überall.

### Claude Code

```bash
claude plugin marketplace add jeremy-anny/anny-posthog-plugin
claude plugin install posthog-anny@anny
```

Dann in einer Session `/mcp`, `plugin:posthog-anny:posthog` auswählen, Enter —
der Browser öffnet den OAuth-Flow.

Der Name ist bewusst `posthog-anny`: wer zusätzlich das offizielle
`posthog@claude-plugins-official` installiert hat, behält beides parallel,
auf zwei verschiedene Instanzen gezeigt.

### Cursor / Codex / Gemini CLI

`.cursor-plugin/`, `.codex-plugin/` und `gemini-extension.json` sind
mitgespiegelt und zeigen ebenfalls auf `mcp.anny.cloud`.

### Optional: Claude-Code-Sessions in LLM Analytics

In `~/.claude/settings.json`:

```json
{
  "env": {
    "POSTHOG_LLMA_CC_ENABLED": "true",
    "POSTHOG_API_KEY": "phc_…",
    "POSTHOG_HOST": "https://p.anny.cloud"
  }
}
```

Der `POSTHOG_HOST`-Default ist im Spiegel schon auf `p.anny.cloud` gepatcht —
er steht hier nur der Klarheit halber.

---

## Für Betreiber: was vorher stehen muss

Das Plugin ist nur ein Zeiger. Damit er ins Leere zeigt oder nicht, braucht es
den MCP-Server.

### 1. MCP-Server deployen

PostHog baut ihn als eigenes, öffentliches Image (`services/mcp/` im Monorepo,
Hono auf Node, Redis für Session-State). Kein Fork nötig — self-hosting ist
vorgesehen, dafür gibt es `POSTHOG_API_BASE_URL`.

```yaml
# clusters/services/posthog-mcp/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: posthog-mcp
  namespace: posthog
spec:
  replicas: 2
  selector: { matchLabels: { app: posthog-mcp } }
  template:
    metadata:
      labels: { app: posthog-mcp }
    spec:
      containers:
        - name: mcp
          # Per Digest pinnen, wie die anderen PostHog-Images. Der Tag `latest`
          # bewegt sich mehrmals täglich.
          image: ghcr.io/posthog/posthog-mcp@sha256:…
          ports: [{ containerPort: 3001 }]
          env:
            # Der eine Schalter, der aus dem Cloud-Server einen für uns macht.
            # Er steuert AUCH, welchen OAuth-Authorization-Server die
            # RFC-9728-Metadaten nennen — deshalb reicht er für den Login.
            - { name: POSTHOG_API_BASE_URL, value: "https://posthog.anny.cloud" }
            - { name: POSTHOG_PUBLIC_URL,   value: "https://posthog.anny.cloud" }
            # Eigene URL — von hier lädt der Client die MCP-UI-Assets.
            - { name: MCP_APPS_BASE_URL,    value: "https://mcp.anny.cloud" }
            - { name: POSTHOG_MCP_APPS_ANALYTICS_BASE_URL, value: "https://posthog.anny.cloud" }
            - { name: POSTHOG_ANALYTICS_HOST, value: "https://posthog.anny.cloud" }
            - { name: REDIS_URL, value: "redis://posthog-mcp-redis:6379" }
            - { name: PORT, value: "3001" }
            # Mindestens 32 Byte (openssl rand -hex 32). Fehlt er, bootet der
            # Server trotzdem, aber alle Tools mit Bestätigungsschritt sind tot.
            - name: MCP_SIGNED_STATE_KEY
              valueFrom: { secretKeyRef: { name: posthog-mcp, key: signed-state-key } }
          readinessProbe: { httpGet: { path: /readyz, port: 3001 } }
          livenessProbe:  { httpGet: { path: /healthz, port: 3001 } }
```

Dazu ein kleines Redis (eigenes, nicht das der PostHog-Installation —
der MCP-Server legt dort Session-State unter eigenen Keys ab), ein Service auf
Port 3001 und ein Ingress für `mcp.anny.cloud`.

**`mcp.anny.cloud` und `posthog.anny.cloud` müssen beide öffentlich erreichbar
sein.** Nicht nur aus dem Browser des Users: Anthropics Backend macht die
Client-Registrierung und den Token-Tausch server-seitig. Ein VPN-Allowlist davor
und der Login schlägt fehl. (Der bestehende `adminAllowList` betrifft nur die
Admin-Pfade und ist kein Problem.)

### 2. CORS für die Consent-Seite

Die Consent-Seite in PostHog holt die MCP-Metadaten aus dem Browser. Der
MCP-Server setzt die CORS-Header aber nur für eine **hardcodierte** Origin-Liste
(`OAUTH_CONSENT_PAGE_ORIGINS` in `services/mcp/src/lib/oauth-metadata-cors.ts`:
us/eu.posthog.com und localhost) — `posthog.anny.cloud` steht da nicht drin.

Kein Image-Fork nötig, das erledigt der Ingress:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: mcp-oauth-cors
  namespace: posthog
spec:
  headers:
    accessControlAllowOriginList: ["https://posthog.anny.cloud"]
    accessControlAllowMethods: ["GET", "OPTIONS"]
    accessControlAllowHeaders: ["Content-Type"]
    accessControlMaxAge: 3600
    addVaryHeader: true
```

An die IngressRoute für `/.well-known/oauth-protected-resource` hängen.

### 3. Prüfen

```bash
.anny/check-oauth.sh
```

Läuft genau die Sequenz ab, die die Claude App beim ersten Aufruf abläuft, und
sagt bei einem Fehler welcher Schritt: 401 mit `WWW-Authenticate`,
RFC-9728-Metadaten mit der richtigen Authorization-Server-URL, CORS-Header,
RFC-8414-Metadaten mit `registration_endpoint`, und ob DCR unauthentifiziert
antwortet.

Mit `--register` macht es zusätzlich eine echte Registrierung und gibt die
`client_id` aus (danach unter *Settings → Connected apps* wieder löschen).

---

## Wie der Login abläuft

```
Claude ──POST /mcp──────────────────────► mcp.anny.cloud
       ◄─401 + WWW-Authenticate──────────
       ──GET /.well-known/oauth-protected-resource/mcp──►
       ◄─{"authorization_servers":["https://posthog.anny.cloud"]}
       ──GET /.well-known/oauth-authorization-server───► posthog.anny.cloud
       ◄─{…,"registration_endpoint":"…/oauth/register/"}
       ──POST /oauth/register───────────► (RFC 7591, unauthentifiziert)
       ◄─{"client_id":…}
  User ──/oauth/authorize im Browser────► Consent-Screen → Authorize
Claude ──POST /oauth/token──────────────► access_token
```

Kein Personal API Key, kein Project Token — in der Claude App gibt es für einen
Plugin-Connector gar kein Feld, wo man einen Header hinterlegen könnte. Der
`phx_`-Bearer-Weg existiert weiter, ist aber nur für CLI und Skripte.

Die DCR-View im PostHog ist bewusst offen (`permission_classes = []`,
`authentication_classes = []`), nur IP-Rate-Limits davor. Registrierte Clients
stehen unter *Settings → Connected apps*; entziehen geht dort einzeln.
Organisationsweit read-only lässt sich das Ganze unter
*Organization settings → Security → „Restrict MCP access to read-only"* stellen.

---

## Repo-Sichtbarkeit

Die beiden Verteilwege haben **gegensätzliche** Anforderungen:

| Weg | Sichtbarkeit | warum |
|---|---|---|
| Persönlicher Marketplace (Customize → Plugins) | **public** | Der Sync läuft server-seitig aus einer unauthentifizierten GitHub-Session |
| Org-Marketplace (Team/Enterprise, Organization settings → Plugins) | **private oder internal** — public ist nicht erlaubt | Claude GitHub App als Installations-Token |
| Claude Code CLI | egal | nutzt die lokalen git-Credentials |

Deshalb liegt das Plugin im **selben** Repo wie der Marketplace
(`"source": "./"`). Ein Marketplace, der auf ein separates privates Plugin-Repo
zeigt, scheitert im persönlichen Weg mit einem nichtssagenden
„Marketplace sync failed".

Geheim ist hier nichts: ein MIT-Fork plus eine URL, die durch OAuth geschützt
ist und deren OAuth-Metadaten ohnehin öffentlich sind.

---

## Wie der Spiegel funktioniert

Kein Fork-und-Merge. Bei jedem Sync wird der Baum **weggeworfen und aus
Upstream neu aufgebaut**, danach werden die Patches erneut angewendet. Damit
gibt es nie einen Konflikt — entweder alle Patches landen, oder der Sync
schlägt fehl und nennt den Anker, der sich bewegt hat.

```
.anny/
  config.env         ← alle Werte, die man je ändern will
  sync-upstream.sh   ← Baum neu bauen (lokal oder in CI)
  apply-patches.sh   ← die Patches, mit Anker-Assertions
  check-oauth.sh     ← Preflight für MCP + DCR
  workflows/         ← kanonische Kopie des Workflows
  UPSTREAM_SHA       ← woraus der aktuelle Stand gebaut ist
```

Alles außerhalb von `.anny/` und `.git/` gehört Upstream.

Der Workflow läuft nachts und öffnet einen **PR**, keinen Push. Die ~160 Skills
steuern `exec`-Subcommands, und das sind API-Aufrufe gegen unser Django: ein
Plugin, das der gepinnten PostHog-Version vorausläuft, ruft Endpunkte auf, die
es bei uns noch nicht gibt. Der Diff ist das Review — derselbe bewusste Schritt
wie das Promoten eines Image-Digests.

Etwas ändern (andere MCP-URL, andere Instanz):

```bash
$EDITOR .anny/config.env
.anny/sync-upstream.sh
git commit -am "config: …"
```

### Was gepatcht wird

| Datei | Änderung |
|---|---|
| `.mcp.json`, `mcp.json`, `gemini-extension.json` | MCP-Endpoint → `mcp.anny.cloud` |
| `.claude-plugin/plugin.json` | Name → `posthog-anny` |
| `.claude-plugin/marketplace.json` | Marketplace → `anny`, Plugin-Eintrag |
| `.agents/plugins/marketplace.json` | Quelle → dieses Repo. **Ohne das würde die Claude App aus unserem Marketplace das offizielle Plugin installieren** — mit Cloud-Endpoint. |
| `skills/`, `commands/`, `agents/` | ~250 Deeplinks `us/eu/app.posthog.com` → `posthog.anny.cloud` |
| `posthog_llma/`, `hooks/` | LLMA-Default-Host → `p.anny.cloud` |
| `.github/` | Upstream-CI raus, unser Workflow rein |
| `README.md` | dieses hier; Upstreams liegt als `UPSTREAM_README.md` daneben |

Der Patch-Lauf bricht ab, wenn irgendwo noch `mcp.posthog.com` steht.

---

Upstream: [`PostHog/ai-plugin`](https://github.com/PostHog/ai-plugin) · MIT ·
Skills, Commands und Agents stammen von PostHog.
