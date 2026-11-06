# herdr-gentle

Esto lleva lo que hoy hace **Gentle Shell** a la **app de escritorio [Herdr](https://herdr.dev)** (`herdr-app` + `herdr-core`), sin Gentle Shell ni Pi. No toca la TUI `herdr`.

- **Gentle AI en todos tus agentes:** skills, persona y los MCP **Engram**, **Context7** y **CodeGraph**.
- **Panel *Gentle* en la app:** un mod nativo que lista cada agente y sus subagentes de fondo con rol, modelo, % de contexto, tokens y costo, más el consumo del día.
- **Subagentes de fondo con los roles de Gentle:** explorer, writer, verifier y worker, como *templates* de herdr-core para cualquier agente (claude, codex, opencode, gemini, cursor).
- **Tema Gentleman** para la app.

## Cómo encaja con la app

La app Herdr no es la TUI. Dibuja su interfaz con **mods** (JavaScript sobre GPUI) y corre las terminales en **herdr-core** (`hc`). herdr-core ya entiende de subagentes: si un agente lanza otro con `hc run`, queda registrado como su padre, y la app lo muestra anidado en la barra de agentes. Por eso cada pieza de Gentle Shell tiene un equivalente directo:

| Gentle Shell | En la app Herdr |
| :--- | :--- |
| Tarjetas de subagentes (modelo, tokens, costo) | Mod **Gentle** (barra izquierda, bajo Agents, en el layout *Gentle*): árbol padre → subagentes con modelo, barra de contexto, tokens y costo. Un clic va al agente (`agent.focus`) |
| `/gentle:usage` | Sección **HOY** del panel: sesiones y costo por modelo |
| Aviso de contexto | Notificación de la app cuando un agente pasa del 80% de su contexto. Clic → va al agente |
| Agentes enfocados (explorer, writers, verifier) | Templates `gentle-<rol>-<agente>` + `hc run --bg`. herdr-core los registra como hijos, y la app los muestra y permite *peek* |
| Gentle Changes (`alt+g`) | El panel **Changes** que ya trae la app |
| Tema Gentleman | `themes/gentleman.json` |

```
App Herdr ─ panel Gentle (mod) ── exec ──▶ gentle-usage ──▶ hc ls + archivos de sesión de cada agente
   │
   └─ terminal: claude ── skill gentle-herdr ──▶ hc run --bg gentle-explorer-codex "…"
                       │                              └─ hijo t7 (codex) ── hc send t1 "informe en /tmp/x.md"
                       └─ MCP: engram · context7 · codegraph (Gentle AI)
```

## Instalación

Necesitas `git`, `node`, la **app Herdr** (que instala `hc`), `gentle-ai` y al menos un agente.

```bash
git clone https://github.com/ldmrgrc/herdr-gentle ~/herdr-gentle && cd ~/herdr-gentle
./install.sh --dry-run    # muestra el plan
./install.sh --theme      # --theme también activa el tema Gentleman
```

Si Gentle AI ya está instalado, el instalador solo ejecuta `gentle-ai sync` y no cambia tu selección. Para configurar agentes nuevos usa `--gentle-install`.

El instalador hace esto:

1. Comprueba que estén `herdr-app`, `hc`, `node` y `gentle-ai`.
2. Detecta tus agentes. Rechaza `pi`, que es el runtime de Gentle Shell.
3. Ejecuta `gentle-ai sync`, o `gentle-ai install` si Gentle AI no está instalado.
4. Instala CodeGraph y lo registra en cada agente.
5. Enlaza las skills `herdr-core` (la oficial) y `gentle-herdr` en la carpeta de skills de cada agente. Si encuentra la skill `herdr` de la TUI, te avisa para que la borres.
6. Escribe `~/.config/herdr-core/templates/gentle-{explorer,writer,verifier,worker}-<agente>.md`. Codex se lanza con `--no-daemon`, como pide hc. Los agentes que no reportan estado usan `ready: quiet`.
7. Copia el mod a `~/.config/herdr-app/mods/gentle` y el tema a `~/.config/herdr-app/themes/`. Luego ejecuta `herdr-app check` sobre el mod y enlaza `gentle-usage`, `herdr-gentle-doctor` y `herdr-gentle-init` en `~/.local/bin`.

No modifica tu `keys.json` ni los layouts que trae la app. La app nunca acopla mods nuevos en sus layouts de fábrica (`main`, `terminals`, `win98`), así que el instalador crea un layout personal **Gentle**: tu `main` con el panel Gentle bajo Agents. Además, cambia la app a ese layout. Con `--theme`, el tema Gentleman va solo en ese layout. `ctrl-shift-l` cambia entre layouts. Cada cambio queda anotado para que `./uninstall.sh` lo pueda deshacer.

## Uso

Abre la app y lanza tu agente. Después pídele, por ejemplo:

- *"explora cómo funciona la autenticación con un subagente codex"*
- *"verifica este cambio con un agente distinto al que lo escribió"*

La skill `gentle-herdr` aplica las reglas de delegación de Gentle AI: delegar solo con una razón concreta, pasar la tarea como archivo y nunca resumida, y usar un verificador independiente. Por debajo hace esto:

```bash
hc templates                                   # gentle-explorer-codex, gentle-writer-claude, …
hc run --bg --name exp-auth --cwd "$PWD" gentle-explorer-codex \
  "Task: read /tmp/task.md. Parent: $HC_TERMINAL_ID. Result file: /tmp/exp-auth.md. Report with hc send $HC_TERMINAL_ID."
hc wait --children all
```

Puedes ver el consumo sin la app:

```bash
gentle-usage --table
```

## De dónde salen los números

herdr-core no sabe qué sesión corre cada agente. `gentle-usage` lo deduce cruzando la carpeta y la hora de inicio de cada terminal, y nunca asigna el mismo archivo a dos terminales.

| Agente | Fuente | Costo |
| :--- | :--- | :--- |
| Claude Code | `~/.claude/projects/<carpeta>/*.jsonl` | estimado (≈) |
| Codex | `~/.codex/sessions/AAAA/MM/DD/*.jsonl` (cruza por `cwd`; usa la ventana de contexto real) | estimado (≈) |
| OpenCode | `opencode.db` (necesita `sqlite3`) | **real** |
| Gemini CLI | `~/.gemini/tmp/<hash>/chats/` | estimado (≈) |

Los costos estimados salen de `usage/prices.json`. Para corregirlos, copia ese archivo a `~/.config/herdr-gentle/prices.json` y edítalo. **Revisa esos precios:** son valores de referencia. Con una suscripción, fíjate más en los tokens y el % de contexto.

## Notas

- **Estado de los agentes:** la app muestra como agente a todo programa que reporta su estado con OSC 7501; Claude Code y Codex lo hacen. Si un agente no lo reporta, igual corre con su template, pero la app no lo marca como trabajando o bloqueado.
- **CodeGraph:** para que su guía aparezca en el prompt del agente, ejecuta `gentle-ai` una vez y marca *Community Tools → CodeGraph*.
- **Actualizar:** `git pull && ./install.sh`. Las skills son enlaces y se actualizan solas; el mod y los templates se vuelven a copiar.
- **Plataformas:** probado para Linux y macOS. Windows queda pendiente.

## Desinstalar

```bash
./uninstall.sh --dry-run   # muestra qué va a deshacer
./uninstall.sh
```

El instalador anota cada cambio en `~/.local/state/herdr-gentle/install.log`. `uninstall.sh` lo deshace en orden inverso y te deja la máquina como estaba antes de instalar:

- Borra lo que creó: skills, templates, el mod, el tema y los comandos de `~/.local/bin`. Si pisó un archivo tuyo, lo restaura desde la copia que guardó, y borra las carpetas que creó si quedan vacías.
- Quita CodeGraph **solo** de los agentes donde lo puso él (`codegraph uninstall --target … --keep-cli`). La CLI de CodeGraph solo la desinstala si la instaló él.
- Quita el índice de CodeGraph (`codegraph uninit`) de los proyectos que indexó `herdr-gentle-init`, y la línea `.codegraph/` del `exclude` si la agregó él.
- Vuelve a poner el tema de la app que tenías.
- Restaura Gentle AI al backup que el propio `gentle-ai` guardó justo antes de la instalación (`gentle-ai restore <id>`). Con `--keep-gentle` se salta este paso. **Ojo:** eso también deshace los cambios que hayas hecho en la configuración de tus agentes después de instalar.

Antes de cambiar nada te pide confirmación (`--yes` para no preguntar). Si algún paso falla, conserva el registro para que puedas volver a ejecutarlo.

Dos cosas no puede deshacer solo:
- Si el panel Gentle quedó acoplado en la app, ciérralo.
- Si `gentle-ai install` instaló Engram y no lo quieres, desinstálalo con tu gestor de paquetes.
