#!/usr/bin/env python3
"""
Clean up unnecessary files in scripts directory
"""

from pathlib import Path
import shutil

# Files to keep (essential)
ESSENTIAL_FILES = {
    "setup-keycloak.ps1",
    "setup-db-migrations.ps1",
    "setup-apisix.ps1",
    "bootstrap.ps1",
    "arda-manager.py",
    "requirements.txt",
    "README.md",
    "cleanup-scripts.py",
}

# Files to delete (temporary, redundant, obsolete)
FILES_TO_DELETE = [
    # Temporary output files
    "init-db.sql",
    "oidc.txt",
    "output.txt",
    "keycloak_output.txt",

    # Test files
    "test.ps1",

    # Obsolete scripts
    "teardown.ps1",

    # Replaced by arda-manager.py
    "generate-jwt-keys.ps1",
    "generate-jwt-keypair.ps1",
    "generate-jwt-keypair-openssl.ps1",
    "generate-jwt-keypair.py",
    "RESET.md",
    "reset-full.ps1",
]

def cleanup():
    scripts_dir = Path(__file__).parent

    print("=" * 60)
    print("  Arda Scripts Cleanup")
    print("=" * 60)
    print()

    # Check files to delete
    deleted = []
    kept = []

    for file_path in scripts_dir.iterdir():
        if file_path.is_file():
            filename = file_path.name
            if filename in FILES_TO_DELETE:
                try:
                    file_path.unlink()
                    deleted.append(filename)
                    print(f"  [red]✗[/red] Deleted: {filename}")
                except Exception as e:
                    print(f"  [yellow]⚠[/yellow] Error deleting {filename}: {e}")
            else:
                kept.append(filename)

    print()
    print(f"[green]Deleted {len(deleted)} files[/green]")
    print(f"[blue]Kept {len(kept)} files[/blue]")

    if deleted:
        print()
        print("[yellow]Files deleted:[/yellow]")
        for filename in deleted:
            print(f"  - {filename}")

    print()
    print("[bold green]✓ Cleanup complete![/bold green]")

if __name__ == "__main__":
    cleanup()
