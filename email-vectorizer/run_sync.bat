@echo off
echo === Incremental Email Sync - qwen3-embedding:8b ===
echo.
echo Make sure:
echo   1. Outlook is open
echo   2. Qdrant is running (http://localhost:6333)
echo   3. Ollama is running (http://localhost:11434)
echo.
cd /d "%~dp0"
rem Le point apres %%~dp0 evite que le \ final echappe le guillemet fermant.
uv run --project "%~dp0." python sync_emails.py %*
pause
