# herdr-gentle

Usa **las skills, la configuración y los MCP de [Gentle AI](https://github.com/Gentleman-Programming/gentle-ai)** dentro de **[herdr](https://herdr.dev)**, **sin Gentle Shell**.

## La idea

| Pieza | Qué hace | Papel aquí |
| :--- | :--- | :--- |
| **herdr** | Multiplexor de terminal para agentes: paneles, estado (working/blocked/idle), sesiones persistentes | La "app" donde viven tus agentes |
| **Gentle AI** (`gentle-ai`) | Configurador: escribe skills, persona, permisos y MCP en la config **nativa** de cada agente | Aporta el ecosistema |
| **Gentle Shell** | Runtime propio basado en Pi, con su propia interfaz | **No se usa** |

Gentle AI ya funciona sin Gentle Shell: configura agentes como Claude Code u OpenCode. herdr no envuelve a los agentes, solo gestiona sus terminales. Así que la combinación queda así:

```
herdr  ──(panel)──▶  claude / opencode / codex / gemini / cursor-agent
                         │
                         ├─ skills + persona + permisos   ← gentle-ai install
                         ├─ MCP engram     (memoria)      ← gentle-ai install
                         ├─ MCP context7   (docs vivas)   ← gentle-ai install
                         ├─ MCP codegraph  (grafo código) ← codegraph install
                         └─ skill herdr + hook de sesión  ← herdr integration / skill
```

## Requisitos

- `git`, `node` y `npm` (Context7 y CodeGraph usan npm)
- herdr: `curl -fsSL https://herdr.dev/install.sh | sh` o `brew install herdr`
- gentle-ai: `brew install gentleman-programming/tap/gentle-ai`
  o `go install github.com/gentleman-programming/gentle-ai/v4/cmd/gentle-ai@latest`
- Al menos un agente: `claude`, `opencode`, `codex`, `gemini` o `cursor-agent`

`gentle-ai install` instala Engram si no lo tienes.

## Instalación

```bash
git clone <este repo> ~/herdr-gentle && cd ~/herdr-gentle
./install.sh --dry-run     # muestra el plan, no cambia nada
./install.sh               # configura los agentes detectados en PATH
```

Opciones útiles:

```bash
./install.sh --agents claude-code,opencode
./install.sh --persona neutral            # gentleman (defecto) | neutral | custom
./install.sh --skills branch-pr,issue-creation,comment-writer
./install.sh --no-codegraph --no-herdr-keys
```

El instalador hace esto:

1. Comprueba los prerrequisitos.
2. Detecta los agentes. Rechaza `pi`, porque es el runtime de Gentle Shell.
3. Ejecuta `gentle-ai install --component engram,skills,context7,persona,permissions`, que configura las skills, la persona, la lista de rutas denegadas y los MCP **Engram** y **Context7**. gentle-ai hace un backup antes de cada escritura.
4. Instala **CodeGraph** (`npm i -g @colbymchenry/codegraph`) y ejecuta `codegraph install --target … --location global`. gentle-ai solo ofrece CodeGraph desde su TUI, así que este paso replica lo que hace su instalador.
5. Instala `herdr integration install <agente>`, que reanuda la sesión del agente tras reiniciar herdr. También añade la skill `herdr`, para que el agente pueda manejar paneles y agentes vecinos.
6. Añade atajos a `~/.config/herdr/config.toml` dentro de un bloque marcado, con backup previo. También enlaza `herdr-gentle-doctor` y `herdr-gentle-init` en `~/.local/bin`.

Puedes volver a ejecutarlo cuantas veces quieras: no duplica nada.

## Uso diario

```bash
cd mi-proyecto
herdr-gentle-init .        # indexa el proyecto con CodeGraph (una vez por repo)
herdr                      # abre herdr y lanza tu agente en un panel
```

Atajos dentro de herdr:

| Atajo | Acción |
| :--- | :--- |
| `prefix+alt+m` | `engram tui`: navegar la memoria |
| `prefix+alt+g` | Indexar con CodeGraph el proyecto del panel activo |
| `prefix+alt+d` | `herdr-gentle-doctor`: verificar skills, MCP e integraciones |
| `prefix+alt+s` | `gentle-ai sync`: actualizar tras subir de versión gentle-ai |

## Verificar los MCP

```bash
herdr-gentle-doctor
```

Para cada agente, el doctor revisa que **engram**, **context7** y **codegraph** aparezcan en `claude mcp list`, `opencode mcp list`, etc. También comprueba la skill `herdr` y las integraciones de herdr, y ejecuta `gentle-ai doctor`. Si falta algo, termina con un código de salida distinto de 0.

## Notas

- **Guía de CodeGraph en el prompt:** el MCP queda instalado, pero el texto de guía que gentle-ai añade al prompt del agente sobre cuándo usar CodeGraph solo se escribe si CodeGraph está seleccionado en su TUI. Para tenerlo, ejecuta `gentle-ai` una vez y marca *Community Tools → CodeGraph*. Los siguientes `gentle-ai sync` lo mantienen.
- **Ámbito:** la configuración es global (`~/.claude`, `~/.config/opencode`, …). Para un solo proyecto usa `gentle-ai install --scope workspace …` dentro del repo.
- **Revertir:** gentle-ai guarda backups en `~/.gentle-ai/backups` (`gentle-ai restore`). Para quitar los atajos, borra el bloque `# >>> herdr-gentle >>>` del config de herdr.
