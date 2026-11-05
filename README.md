# herdr-gentle

Esto lleva a **[herdr](https://herdr.dev)** lo que hoy hace **Gentle Shell**, sin depender de Gentle Shell ni de Pi:

- **Gentle AI en todos tus agentes:** skills, persona y los MCP **Engram**, **Context7** y **CodeGraph**.
- **Consumo en vivo:** modelo, % de contexto, tokens y costo de cada agente en la barra lateral de herdr.
- **Agentes en segundo plano:** cualquier agente puede delegar en subagentes de cualquier tipo (claude, codex, opencode, gemini, cursor). Se aplican las reglas de Gentle AI y se ven en vivo.
- **Panel Gentle:** vistas de Agentes, Consumo y Cambios, el equivalente a `alt+a`, `/gentle:usage` y `alt+g`.

## Cómo encaja

Gentle Shell es una interfaz propia montada sobre Pi. herdr ya es la interfaz donde viven tus agentes y tiene una API abierta: plugins, eventos, metadatos por panel y control de agentes. Así que cada pieza de Gentle Shell tiene su equivalente en herdr:

| Gentle Shell | En herdr con este kit |
| :--- | :--- |
| Tarjetas de subagentes (modelo, tokens, costo, tiempo) | Barra lateral: `$model`, `$ctx`, `$tok` y `$cost` por panel. El plugin las actualiza en cada cambio de estado del agente |
| Gentle Agents (`alt+a`) | `prefix+a`: panel con todos los agentes y sus subagentes (rol ← padre). Desde ahí puedes ir a uno, leer su salida, interrumpirlo o cerrarlo |
| Uso del proveedor (`/gentle:usage`) | `prefix+u`: sesiones abiertas y total del día por modelo |
| Gentle Changes (`alt+g`) | `prefix+alt+c`: cambios sin commitear de cada repo y worktree donde trabajan tus agentes |
| Subagentes de Pi (explorer, writers, verifier) | `gentle-herdr spawn` y la skill `gentle-herdr`: cada subagente es un agente real en una pestaña de fondo `gentle:agents` |
| Resumen de actividad en herdr | `gentle-herdr status "..."` lo muestra como `$summary` en la barra lateral |
| Aviso de contexto | `$ctxwarn` en rojo cuando un agente pasa del 80% de su contexto |

```
herdr
 ├─ panel: claude ─┬─ skill gentle-herdr ──▶ gentle-herdr spawn ──▶ pestaña "gentle:agents"
 │                 │                                                  ├─ exp-auth (codex, explorer)
 │                 │                                                  └─ ver-fix (opencode, verifier)
 │                 └─ MCP: engram · context7 · codegraph  (Gentle AI)
 ├─ plugin gentle.herdr ── evento pane.agent_status_changed ──▶ lee la sesión del agente ──▶ $model $ctx $tok $cost
 └─ prefix+a / prefix+u / prefix+alt+c ──▶ panel Gentle
```

## Instalación

Necesitas `git`, `node`, **herdr ≥ 0.9.0**, `gentle-ai` y al menos un agente.

```bash
git clone https://github.com/ldmrgrc/herdr-gentle ~/herdr-gentle && cd ~/herdr-gentle
./install.sh --dry-run    # muestra el plan
./install.sh
```

Si Gentle AI ya está instalado, el instalador solo ejecuta `gentle-ai sync` y no cambia tu selección. Para configurar agentes nuevos usa `--gentle-install`. Otras opciones: `--agents claude-code,codex`, `--no-sidebar`, `--no-keys`, `--no-codegraph` y `--skip-gentle`.

El instalador hace esto:

1. Comprueba los prerrequisitos.
2. Detecta los agentes. Rechaza `pi`, que es el runtime de Gentle Shell.
3. Ejecuta `gentle-ai sync`, o `gentle-ai install` si Gentle AI no está instalado.
4. Instala CodeGraph y lo registra en cada agente.
5. Instala las skills `herdr` y `gentle-herdr` en la carpeta de skills de **cada** agente (enlace simbólico: un `git pull` las actualiza) y las integraciones de herdr.
6. Ejecuta `herdr plugin link plugin/` y enlaza `gentle-herdr`, `herdr-gentle-doctor` y `herdr-gentle-init` en `~/.local/bin`.
7. Añade los atajos y la barra lateral a `~/.config/herdr/config.toml`, con backup previo. Si ya tienes `[ui.sidebar.agents]`, no la toca y te avisa.

## Uso

```bash
cd mi-proyecto
herdr-gentle-init .      # índice de CodeGraph (una vez por repo)
herdr                    # abre tu agente en un panel
```

Pídele al agente, por ejemplo: *"explora cómo funciona la autenticación con un subagente codex"* o *"verifica este cambio con un agente distinto al que lo escribió"*. La skill `gentle-herdr` le enseña a hacerlo así:

```bash
gentle-herdr spawn exp-auth --kind codex --role explorer --task-file /tmp/tarea.md
gentle-herdr wait exp-auth
gentle-herdr result exp-auth
gentle-herdr list                     # estado, rol, contexto, tokens y costo de todos
gentle-herdr status "ODD 2/4 · implementando refresh"
```

La tarea se pasa **por referencia**: el subagente recibe un archivo, no un resumen, como pide Gentle AI. Así no se pierden strings exactos ni criterios. El subagente escribe su informe en `~/.local/state/gentle-herdr/runs/<nombre>.result.md`.

| Atajo | Acción |
| :--- | :--- |
| `prefix+a` | Panel de agentes |
| `prefix+u` | Consumo |
| `prefix+alt+c` | Cambios sin commitear |
| `prefix+alt+m` | Memoria Engram |
| `prefix+alt+g` | Indexar con CodeGraph el proyecto del panel |
| `prefix+alt+d` | `herdr-gentle-doctor` |

Dentro del panel: `1`/`2`/`3` cambia de vista, `↑↓` elige, `enter` va al agente (o abre el diff en Cambios), `r` lee su salida, `x` lo interrumpe, `c` cierra su panel y `q` sale.

## Consumo: de dónde salen los números

El plugin lee los archivos de sesión de cada agente. Para saber qué sesión corresponde a qué panel usa la integración de herdr (`agent_session`).

| Agente | Fuente | Costo |
| :--- | :--- | :--- |
| Claude Code | `~/.claude/projects/*/<sesión>.jsonl` | estimado (≈) |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl` (incluye la ventana de contexto real) | estimado (≈) |
| OpenCode / Kilo | `storage/message/<sesión>/` u `opencode.db` | **real**, el que reporta OpenCode |
| Gemini CLI | `~/.gemini/tmp/*/chats/` | estimado (≈) |

Los costos estimados son el equivalente en precio de API y salen de `prices.json`. Ese archivo se copia en `herdr plugin config-dir gentle.herdr`, donde puedes editarlo. **Revisa esos precios:** son valores de referencia. Si usas una suscripción (Claude Max o ChatGPT Pro), fíjate más en los tokens y en el % de contexto que en el costo.

## Notas

- Para que la guía de CodeGraph aparezca en el prompt del agente, ejecuta `gentle-ai` una vez y marca *Community Tools → CodeGraph*. El MCP ya queda instalado sin eso.
- El plugin no corre en segundo plano todo el tiempo: se ejecuta en cada evento de herdr y termina.
- Hoy está preparado para Linux y macOS. Windows queda pendiente.
- Para quitarlo: `herdr plugin unlink gentle.herdr`, borra el bloque `# >>> herdr-gentle >>>` del config de herdr, y para la configuración de Gentle AI usa `gentle-ai restore`.
