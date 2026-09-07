# PostHog Plugin (anny)

Spiegel von [`PostHog/ai-plugin`](https://github.com/PostHog/ai-plugin), umgebogen
auf unser selbst gehostetes PostHog unter **https://posthog.anny.cloud**.

Identisch zum offiziellen Plugin — ~160 Skills, Slash-Commands, `error-analyzer`,
LLM-Analytics-Hook — nur zeigt der MCP-Connector auf `posthog.anny.cloud/mcp` statt auf
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

Das Plugin ist nur ein Zeiger. Der MCP-Server selbst kommt aus dem
`gitops-services`-Repo: `charts/posthog/templates/mcp.yaml` rendert Secret,
Deployment und Service, und `ingressRoutes.mcp.paths` hängt `/mcp` als eigenen
Ingress an den bestehenden PostHog-Host. Kein zweiter Hostname, kein zweites
Zertifikat.

Ein Host ist die bessere Wahl, und zwar aus einem Grund, der leicht untergeht:
die Consent-Seite in PostHog holt die MCP-Metadaten aus dem Browser. Auf einem
eigenen `mcp.*`-Host wäre das cross-origin, und der MCP-Server setzt die
CORS-Header nur für eine hardcodierte Liste (`OAUTH_CONSENT_PAGE_ORIGINS`:
us/eu.posthog.com und localhost). Auf demselben Host ist es same-origin und die
Frage stellt sich nicht.

### Drei Dinge, ohne die der OAuth-Weg nicht funktioniert

**1. `OIDC_RSA_PRIVATE_KEY` muss gesetzt sein.**

Die DCR-View legt den Client mit `algorithm="RS256"` an, und Django weigert
sich, so eine `OAuthApplication` ohne RSA-Key zu speichern. Ohne den Key
antwortet `/oauth/register/` mit `500 server_error: Failed to create client` —
der Grund wird bewusst nicht nach außen gegeben (`"Other validation errors
(like missing RSA key) are internal and should not be leaked"`).

Der Key gehört in den `posthog-app`-Container in Scaleway Secret Manager und in
den `secrets:`-Block der zugehörigen ExternalSecret; von dort landet er über
`templates/secret.yaml` in `posthog-secrets` und damit im Env jedes Pods.
Achtung beim Template: ein PEM hat Zeilenumbrüche und passt nicht in einen
`"{{ .X }}"`-Skalar.

```bash
openssl genrsa -out oidc.pem 4096
```

Derselbe fehlende Key lässt auch den `llm-gateway-credentials`-Hook-Job
scheitern (`setup_tasks_oauth`).

**2. `mcp.apiBaseUrl` muss die öffentliche URL sein.**

Der Chart-Default ist `http://web:8000`, und der MCP-Server benutzt genau diesen
Wert als OAuth-Issuer:

```ts
export const resolveAuthorizationServerUrl = (): string => {
    if (isCloudApi()) return OAUTH_PROXY_URL
    return getCustomApiBaseUrl()!        // = POSTHOG_API_BASE_URL
}
```

Mit `http://web:8000` sagt die RFC-9728-Antwort
`authorization_servers: ["http://web:8000"]` — eine Adresse, die kein Client
erreicht, und die Discovery endet dort. `POSTHOG_PUBLIC_URL` hilft nicht, das
ist nur für gerenderte Links.

Eine Falle daneben: `isCloudApi()` behandelt jeden Hostnamen auf
`.svc.cluster.local` als Cloud und liefert dann `https://oauth.posthog.com` —
also PostHog Cloud als Issuer. Cluster-interne Namen sind hier in beiden
Varianten falsch. Richtig ist `https://posthog.anny.cloud`.

Folge davon: der MCP-Pod ruft die PostHog-API dann über den öffentlichen Ingress
auf und läuft damit in die `adminAllowList` — die Quelladresse ist eine Pod-
bzw. Node-Adresse, keine der drei erlaubten. Die braucht eine Ausnahme.

**3. Die `adminAllowList` darf nicht auf dem MCP-Ingress liegen.**

`templates/ingress.yaml` hängt die Middleware an den `posthog-mcp`-Ingress,
sobald `ingress.adminAllowList.enabled` true ist. Das ist für einen lokalen
Client richtig — für einen gehosteten nicht: die Claude App verbindet sich von
Anthropics Servern aus, nicht vom Rechner des Users. Dasselbe gilt für
`/oauth/register/` und `/oauth/token/`, die serverseitig aufgerufen werden.

Wer das Plugin über die Claude App verteilen will, muss `/mcp` und die
OAuth-Pfade offen lassen; Session-Cookie und OAuth-Scopes sind die
Zugangskontrolle, nicht die IP.

### Und ein Routing-Detail

`ingressRoutes.mcp.paths` enthält nur `/mcp`. Die Discovery-URL nach RFC 9728
ist aber `/.well-known/oauth-protected-resource/mcp` — der Client schiebt das
Präfix zwischen Host und Pfad. Der Pfad geht heute an Django und endet in einem
302 auf `/login`. Er muss mit in die Liste:

```yaml
ingressRoutes:
  mcp:
    port: 3001
    paths:
    - /mcp
    - /.well-known/oauth-protected-resource/mcp
```

Django behält dabei seinen eigenen `/.well-known/oauth-protected-resource`
ohne Suffix — der Chart rendert `pathType: Exact` auf den Pfad und `Prefix` auf
Pfad + `/`, überdeckt den kürzeren also nicht.

Kosmetisch, aber derselbe Mechanismus: `MCP_APPS_BASE_URL` ist im Chart nicht
gesetzt und `/ui-apps/*` nicht geroutet — die interaktiven MCP-UI-Ansichten
laden dann nicht. Tools funktionieren davon unabhängig.

### Prüfen

```bash
.anny/check-oauth.sh
```

Läuft genau die Sequenz ab, die die Claude App beim ersten Aufruf abläuft, und
sagt bei einem Fehler welcher Schritt.

**Der read-only-Lauf reicht nicht.** Dass `/oauth/register/` auf einen leeren
Body mit `400 invalid_client_metadata` antwortet, beweist nur, dass die View
lebt — die Serializer-Validierung läuft vor dem Anlegen. Ob eine echte
Registrierung durchgeht, zeigt erst:

```bash
.anny/check-oauth.sh --register
```

Das legt einen echten OAuth-Client an und gibt die `client_id` aus (danach unter
*Settings → Connected apps* löschen).

## Wie der Login abläuft

```
Claude ──POST /mcp──────────────────────► posthog.anny.cloud/mcp
       ◄─401 + WWW-Authenticate──────────
       ──GET /.well-known/oauth-protected-resource/mcp──►
       ◄─{"authorization_servers":["https://posthog.anny.cloud"]}
       ──GET /.well-known/oauth-authorization-server───►
       ◄─{…,"registration_endpoint":"…/oauth/register/"}
       ──POST /oauth/register───────────► (RFC 7591, unauthentifiziert)
       ◄─{"client_id":…}
  User ──/oauth/authorize im Browser────► Consent-Screen → Authorize
Claude ──POST /oauth/token──────────────► access_token
```

Alles auf einem Host: Schritt 1 und 2 beantwortet der MCP-Server, Schritt 3 bis 6
Django. Der Ingress entscheidet anhand des Pfads, wer antwortet.

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
| `.mcp.json`, `mcp.json`, `gemini-extension.json` | MCP-Endpoint → `posthog.anny.cloud/mcp` |
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
