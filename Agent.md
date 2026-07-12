# Agent.md

## 1. Deployment Configuration

### Target Space
- **Profile:** `Leon4gr45`
- **Space:** `augmenttoolkit`
- **Full Identifier:** `Leon4gr45/augmenttoolkit`
- **Frontend Port:** `7860` (mandatory for all Hugging Face Spaces)

### Deployment Method
Choose the correct SDK based on the app type based on the codebase language:

- **Gradio SDK** — for Gradio applications
- **Streamlit SDK** — for Streamlit applications
- **Docker SDK** — for all other applications (recommended default for flexibility)

### HF Token
- The environment variable **`HF_TOKEN` will always be provided at execution time**.
- Never hardcode the token. Always read it from the environment.
- All monitoring and log‑streaming commands rely on `HF_TOKEN`.

### GitHub Sync (Persistence)
- The environment variable **`PAT_TOKEN`** must be set with a GitHub Personal Access Token.
- This token is used to sync the internal SQLite database (`travel.db`) to `https://github.com/JsonLord/TREK.git` on the `custom-data` branch.
- Sync runs on startup and every 6 hours.
- If the branch does not exist, the service will create it.

### Required Files
- `Dockerfile` (or `app.py` for Gradio/Streamlit SDKs)
- `README.md` with Hugging Face YAML frontmatter:
  ```yaml
  ---
  title: trek
  sdk: docker
  app_port: 7860
  ---
  ```
- `.hfignore` to exclude unnecessary files
- This `Agent.md` file (must be committed before deployment)

---

## 2. API Exposure and Documentation

### Mandatory Endpoints
Every deployment **must** expose:

- **`/health`**
  - Returns HTTP 200 when the app is ready.
  - Required for Hugging Face to transition the Space from *starting* → *running*.

- **`/api-docs`**
  - Documents **all** available API endpoints.
  - Must be reachable at:
    `https://leon4gr45-augmenttoolkit.hf.space/api-docs`

### Functional Endpoints

#### /health
- **Method:** GET
- **Purpose:** Health check for Hugging Face Space.
- **Response:** `OK` (200)

#### /api/health
- **Method:** GET
- **Purpose:** Legacy/Application health check.
- **Response:** `{"status": "ok"}` (200)

#### /api-docs
- **Method:** GET
- **Purpose:** Swagger API documentation.
- **Response:** HTML documentation page.

All endpoints listed here appear in `/api-docs` (where applicable).

---

## 3. Deployment Workflow

Precondition: Use the huggingface hub cli hf to check that the space is empty of files and delete any which are still in there and not belonging to the project to be uploaded.

### Standard Deployment Command
After any code change, run:

```bash
hf upload Leon4gr45/augmenttoolkit . . --repo-type=space --delete "*" --exclude ".git/*" --exclude "**/node_modules/*" --exclude "**/dist/*"
```

---

Scan build and run logs # Get build logs (SSE) curl -N
-H "Authorization: Bearer $HF_TOKEN"
"https://huggingface.co/api/spaces/Leon4gr45/augmenttoolkit/logs/build"

Get run logs (SSE) once the build logs succeed
curl -N
-H "Authorization: Bearer $HF_TOKEN"
"https://huggingface.co/api/spaces/Leon4gr45/augmenttoolkit/logs/run"

after 300 seconds to see if the deployment has been successful, and if not, fix the errors of deployment, and redeploy and monitor in a cycle until the space is running and reacts to the api endpoints you created.
