# family finances tools

Script PowerShell (`Set-ApiDeployment.ps1`) que orquesta el deploy de los **otros tres repos** en una sola corrida:

1. Pick interactivo de `clasp deployments` para el **backend**.
2. `clasp push && clasp deploy` (backend).
3. Despliega el Worker de **proxy** (`wrangler deploy`).
4. Despliega **frontend** a Netlify prod.
5. Reescribe `API_URL` en `Index.html` con la URL del Worker.
7. Actualiza la sección correspondiente en `release_info.txt`.

Expuesto también como tareas VS Code en `.vscode/tasks.json` del mono-repo padre.

## Repos relacionados

| Repo | Qué hace este script sobre él | URL |
|------|-------------------------------|-----|
| family finances backend | `clasp push && clasp deploy`, pick del deployment ID | https://github.com/cekuran/ffv3_backend |
| family finances frontend | `netlify deploy --prod`, reescribe `API_URL` | https://github.com/cekuran/ffv3_frontend |
| family finances proxy | `wrangler deploy`, lee `wrangler.toml` | https://github.com/cekuran/ffv3_proxy |

`release_info.txt` se actualiza **solo en su sección** según la acción (`[google-app-script]`, `[cloudflare]`, `[netlify]`). No editar a mano.

## Setup inicial

Requisitos:

- PowerShell 7+ (`pwsh`)
- `clasp` autenticado contra la cuenta del **backend**
- `wrangler` autenticado contra Cloudflare
- `netlify` CLI autenticado
- Acceso a los 4 repos clonados localmente (este script asume layout mono-repo: `../backend`, `../frontend`, `../proxy`)

```bash
git clone git@github.com:cekuran/ffv3_tools.git
# clonar los otros tres como hermanos:
git clone git@github.com:cekuran/ffv3_backend.git ../backend
git clone git@github.com:cekuran/ffv3_frontend.git ../frontend
git clone git@github.com:cekuran/ffv3_proxy.git ../proxy
```

## Uso

```powershell
# Deploy completo: pick del deployment + push + deploy backend + wrangler + netlify
pwsh ./Set-ApiDeployment.ps1 -Description "fix login flow"

# Solo pick + rewrite API_URL (sin redesplegar nada)
pwsh ./Set-ApiDeployment.ps1

# Previsualizar sin ejecutar
pwsh ./Set-ApiDeployment.ps1 -WhatIf
```

El picker muestra los deployments de `clasp deployments` con flechas — selecciona el `@HEAD` para promover, o un deployment existente para fijar la URL en el frontend sin redesplegar.

## Configuración básica

- **Layout de carpetas**: el script asume mono-repo padre con `backend/`, `frontend/`, `proxy/`, `tools/` hermanos. Si trabajas con repos separados, ajustar las rutas en el script.
- **`release_info.txt`**: vive en la raíz del mono-repo. Cada deploy reescribe solo su sección `[google-app-script]`, `[cloudflare]` o `[netlify]`. No commitear secciones que no correspondan a la acción que ejecutaste.
- **`API_URL`** en `frontend/Index.html`: este script la reescribe automáticamente apuntando al Worker. Si lo editas a mano y luego ejecutas el script, se sobrescribirá.

## Estructura

```
tools/
└── Set-ApiDeployment.ps1     # el script entero
```