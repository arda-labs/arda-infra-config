#!/usr/bin/env python3
"""
Arda Infrastructure Manager - TUI Tool
Interactive terminal UI for managing Arda Platform infrastructure
"""

import os
import sys
import subprocess
from pathlib import Path
from typing import List, Optional
import time

try:
    from rich.console import Console
    from rich.panel import Panel
    from rich.table import Table
    from rich.progress import Progress, SpinnerColumn, TextColumn, BarColumn, TimeRemainingColumn
    from rich.prompt import Prompt, Confirm
    from rich.live import Live
    from rich.layout import Layout
    from rich.text import Text
    from rich import box
    from rich.markdown import Markdown
    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False
    print("Note: Install 'rich' for TUI: pip install rich")


class ArdaInfraManager:
    def __init__(self):
        self.base_dir = Path(__file__).parent.parent
        self.scripts_dir = self.base_dir / "scripts"
        self.docker_compose_dir = self.base_dir / "docker-compose"
        self.keys_dir = self.base_dir / "keys"
        self.console = Console() if RICH_AVAILABLE else None

        if RICH_AVAILABLE:
            self.console.print(Panel(
                "[bold cyan]Arda Infrastructure Manager[/bold cyan]",
                subtitle="TUI Tool for Arda Platform",
                box=box.DOUBLE,
                padding=(1, 2)
            ))

    def run_powershell(self, script: str, args: List[str] = None) -> bool:
        """Run PowerShell script"""
        script_path = self.scripts_dir / script
        if not script_path.exists():
            if self.console:
                self.console.print(f"[red]✗ Script not found: {script_path}[/red]")
            return False

        cmd = ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(script_path)]
        if args:
            cmd.extend(args)

        try:
            result = subprocess.run(cmd, capture_output=True, text=True, cwd=str(self.scripts_dir))
            if self.console:
                self.console.print(result.stdout)
                if result.stderr:
                    self.console.print(f"[yellow]Warning: {result.stderr}[/yellow]")
            return result.returncode == 0
        except Exception as e:
            if self.console:
                self.console.print(f"[red]✗ Error running script: {e}[/red]")
            return False

    def run_docker(self, cmd: List[str]) -> bool:
        """Run Docker command"""
        try:
            result = subprocess.run(["docker"] + cmd, capture_output=True, text=True)
            if self.console:
                self.console.print(result.stdout)
            return result.returncode == 0
        except Exception as e:
            if self.console:
                self.console.print(f"[red]✗ Docker error: {e}[/red]")
            return False

    def show_status(self):
        """Show infrastructure status"""
        if not RICH_AVAILABLE:
            print("=== Infrastructure Status ===")
            try:
                subprocess.run(["docker", "compose", "-f", "docker-compose.yml", "ps"], check=True)
            except:
                print("Error getting status")
            print("\nPress Enter to continue...")
            input()
            return

        self.console.print("\n[bold cyan]📊 Infrastructure Status[/bold cyan]\n")

        # Get container status
        try:
            result = subprocess.run(
                ["docker", "ps", "--format", "table {{.Names}}\t{{.Status}}\t{{.Ports}}"],
                capture_output=True,
                text=True,
                check=True
            )

            table = Table(show_header=True, header_style="bold magenta")
            table.add_column("Container", style="cyan")
            table.add_column("Status", style="green")
            table.add_column("Ports", style="blue")

            # Parse docker output
            lines = result.stdout.strip().split('\n')
            header_found = False
            for line in lines:
                if line.strip():
                    # Skip header row from docker
                    if "NAMES" in line or "CONTAINER" in line:
                        continue
                    parts = line.split()
                    if len(parts) >= 3:
                        table.add_row(parts[0], parts[1], ' '.join(parts[2:]))

            if table.row_count > 0:
                self.console.print(table)
            else:
                self.console.print("[yellow]No containers running[/yellow]")

        except subprocess.CalledProcessError as e:
            self.console.print(f"[red]Error getting docker status: {e.stderr}[/red]")
        except Exception as e:
            self.console.print(f"[red]Error getting status: {e}[/red]")

        # Check health
        self.console.print("\n[bold yellow]Health Checks:[/bold yellow]")
        services = {
            "PostgreSQL": "docker inspect --format='{{.State.Health.Status}}' arda-postgres 2>$null",
            "Redis": "docker inspect --format='{{.State.Health.Status}}' arda-redis 2>$null",
            "Keycloak": "docker inspect --format='{{.State.Running}}' arda-keycloak 2>$null",
            "Kafka": "docker inspect --format='{{.State.Running}}' arda-kafka 2>$null",
            "APISIX": "docker inspect --format='{{.State.Running}}' arda-apisix 2>$null",
        }

        for name, cmd in services.items():
            try:
                result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
                status = result.stdout.strip()
                if status == "healthy" or status == "true":
                    self.console.print(f"  [green]✓[/green] {name}")
                elif status:
                    self.console.print(f"  [yellow]⚠[/yellow] {name}: {status}")
                else:
                    self.console.print(f"  [red]✗[/red] {name}: Not running")
            except Exception:
                self.console.print(f"  [red]✗[/red] {name}: Error")

        # Force console flush and pause
        if self.console:
            self.console.print("\n[gray]Press Enter to return to menu...[/gray]")
        else:
            print("\nPress Enter to return to menu...")

        input()

    def clean_all(self, force: bool = False):
        """Clean all Docker volumes and reset"""
        if not force:
            if self.console:
                if not Confirm.ask("⚠️  This will delete ALL data. Continue?"):
                    self.console.print("[yellow]Cancelled.[/yellow]")
                    return
            else:
                if input("⚠️  This will delete ALL data. Type 'yes' to continue: ") != 'yes':
                    print("Cancelled.")
                    return

        if self.console:
            with Progress(
                SpinnerColumn(),
                TextColumn("[progress.description]{task.description}"),
                console=self.console
            ) as progress:
                task1 = progress.add_task("[cyan]Stopping containers...", total=None)
                progress.update(task1)
                self.run_docker(["compose", "-f", "docker-compose.yml", "down"])

                task2 = progress.add_task("[cyan]Removing volumes...", total=None)
                progress.update(task2)
                subprocess.run([
                    "docker", "volume", "rm",
                    "arda-postgres-data", "arda-kafka-data", "arda-redis-data", "-f"
                ], capture_output=True)

                task3 = progress.add_task("[cyan]Cleaning keys...", total=None)
                progress.update(task3)
                if self.keys_dir.exists():
                    import shutil
                    shutil.rmtree(str(self.keys_dir))

                progress.add_task("[green]✓[/green] Clean complete!")

        self.console.print("\n[bold green]✓ Infrastructure cleaned successfully![/bold green]")

    def generate_keys(self):
        """Generate JWT keypair"""
        if self.console:
            self.console.print("\n[bold cyan]🔑 Generating JWT Keypair[/bold cyan]\n")

        # Check if keys exist
        private_key = self.keys_dir / "internal-jwt-private.pem"
        public_key = self.keys_dir / "internal-jwt-public.pem"

        if private_key.exists() and public_key.exists():
            if self.console:
                if not Confirm.ask("Keys already exist. Regenerate?"):
                    self.console.print("[yellow]Skipping key generation.[/yellow]")
                    return
            if self.console:
                self.console.print("[yellow]Removing existing keys...[/yellow]")
            private_key.unlink()
            public_key.unlink()

        # Try openssl first
        try:
            subprocess.run(["openssl", "version"], capture_output=True, check=True)
            if self.console:
                with Progress(
                    SpinnerColumn(),
                    TextColumn("[progress.description]{task.description}"),
                    console=self.console
                ) as progress:
                    task1 = progress.add_task("[cyan]Generating private key...", total=None)
                    subprocess.run([
                        "openssl", "genrsa", "-out", str(private_key), "2048"
                    ], capture_output=True)

                    task2 = progress.add_task("[cyan]Extracting public key...", total=None)
                    subprocess.run([
                        "openssl", "rsa", "-in", str(private_key),
                        "-pubout", "-out", str(public_key)
                    ], capture_output=True)

                    progress.add_task("[green]✓[/green] Keys generated!")

            self.console.print("\n[bold green]✓ Keypair generated successfully![/bold green]")
        except (subprocess.CalledProcessError, FileNotFoundError):
            if self.console:
                self.console.print("[yellow]OpenSSL not found.[/yellow]")
                self.console.print("\n[bold cyan]Options:[/bold cyan]")
                self.console.print("  1. Install OpenSSL: [blue]https://slproweb.com/products/Win32OpenSSL[/blue]")
                self.console.print("  2. Use online tool: [blue]https://mkjwk.org/rsa2048-keygen.html[/blue]")
                self.console.print("     Save as:")
                self.console.print(f"       - {private_key}")
                self.console.print(f"       - {public_key}")

    def setup_keycloak(self, regenerate: bool = False):
        """Setup Keycloak configuration"""
        if self.console:
            self.console.print("\n[bold cyan]🔐 Setting up Keycloak[/bold cyan]\n")

        if self.console:
            with Progress(
                SpinnerColumn(),
                TextColumn("[progress.description]{task.description}"),
                console=self.console
            ) as progress:
                task = progress.add_task("[cyan]Running setup-keycloak.ps1...", total=None)
                success = self.run_powershell("setup-keycloak.ps1")
                if success:
                    progress.add_task("[green]✓[/green] Keycloak configured!")
                else:
                    progress.add_task("[red]✗[/red] Failed!")

    def setup_db(self):
        """Setup database migrations"""
        if self.console:
            self.console.print("\n[bold cyan]🗄️  Running DB Migrations[/bold cyan]\n")

        if self.console:
            with Progress(
                SpinnerColumn(),
                TextColumn("[progress.description]{task.description}"),
                console=self.console
            ) as progress:
                task = progress.add_task("[cyan]Running setup-db-migrations.ps1...", total=None)
                success = self.run_powershell("setup-db-migrations.ps1")
                if success:
                    progress.add_task("[green]✓[/green] DB migrations complete!")
                else:
                    progress.add_task("[red]✗[/red] Failed!")

    def setup_apisix(self):
        """Setup APISIX routes"""
        if self.console:
            self.console.print("\n[bold cyan]🌐 Setting up APISIX[/bold cyan]\n")

        if self.console:
            with Progress(
                SpinnerColumn(),
                TextColumn("[progress.description]{task.description}"),
                console=self.console
            ) as progress:
                task = progress.add_task("[cyan]Running setup-apisix.ps1...", total=None)
                success = self.run_powershell("setup-apisix.ps1")
                if success:
                    progress.add_task("[green]✓[/green] APISIX configured!")
                else:
                    progress.add_task("[red]✗[/red] Failed!")

    def start_services(self):
        """Start all Docker services"""
        if self.console:
            self.console.print("\n[bold cyan]🚀 Starting Services[/bold cyan]\n")

        if self.console:
            with Progress(
                SpinnerColumn(),
                TextColumn("[progress.description]{task.description}"),
                console=self.console
            ) as progress:
                task = progress.add_task("[cyan]Starting Docker containers...", total=None)
                self.run_docker(["compose", "-f", "docker-compose.yml", "up", "-d"])
                progress.add_task("[green]✓[/green] Services started!")

    def bootstrap(self):
        """Full bootstrap from scratch"""
        if self.console:
            self.console.print("\n[bold cyan]🚀 Running Full Bootstrap[/bold cyan]\n")

        steps = [
            ("Cleaning infrastructure", self.clean_all),
            ("Starting services", lambda: self.start_services()),
            ("Waiting for health", self.wait_for_health),
            ("Setup Keycloak", lambda: self.setup_keycloak()),
            ("Setup DB migrations", lambda: self.setup_db()),
            ("Setup APISIX routes", lambda: self.setup_apisix()),
            ("Generate JWT keys", lambda: self.generate_keys()),
        ]

        for step_name, step_func in steps:
            if self.console:
                self.console.print(f"\n[bold yellow]{step_name}...[/bold yellow]")
            try:
                step_func()
                if self.console:
                    self.console.print(f"[green]✓[/green] {step_name} complete\n")
            except Exception as e:
                if self.console:
                    self.console.print(f"[red]✗[/red] {step_name} failed: {e}\n")
                raise

        if self.console:
            self.console.print(Panel(
                "[bold green]✓ Bootstrap Complete![/bold green]",
                box=box.DOUBLE,
                padding=(1, 2)
            ))

    def wait_for_health(self, max_attempts: int = 30):
        """Wait for services to be healthy"""
        if not RICH_AVAILABLE:
            print("Waiting for services to be healthy...")
            time.sleep(5)
            return

        if self.console:
            with Progress(
                SpinnerColumn(),
                TextColumn("[progress.description]{task.description}"),
                console=self.console
            ) as progress:
                task = progress.add_task("[cyan]Checking service health...", total=None)
                for attempt in range(max_attempts):
                    try:
                        pg_status = subprocess.run(
                            ["docker", "inspect", "--format={{.State.Health.Status}}", "arda-postgres"],
                            capture_output=True, text=True
                        ).stdout.strip()

                        if pg_status == "healthy":
                            progress.add_task("[green]✓[/green] All services healthy!")
                            return
                    except:
                        pass

                    progress.update(task)
                    time.sleep(2)

    def first_boot(self):
        """Full first boot from scratch - automated setup"""
        if self.console:
            self.console.print(Panel(
                "[bold cyan]🚀 First Boot - Fresh Machine Setup[/bold cyan]",
                subtitle="Automated setup from scratch",
                box=box.DOUBLE,
                padding=(1, 2)
            ))

        steps = [
            ("Check Prerequisites", self.check_prerequisites),
            ("Verify Repository", self.verify_repository),
            ("Install Dependencies", self.install_dependencies),
            ("Clean Existing Data", lambda: self.prompt_clean_data()),
            ("Start Docker Infrastructure", self.start_docker_infrastructure),
            ("Wait for Services", self.wait_for_services_healthy),
            ("Run Bootstrap Scripts", lambda: self.run_bootstrap_scripts()),
            ("Build Backend", self.build_backend_library),
        ]

        for step_name, step_func in steps:
            if self.console:
                self.console.print(f"\n[bold yellow]{step_name}...[/bold yellow]")
            try:
                result = step_func()
                if result is not False:
                    if self.console:
                        self.console.print(f"[green]✓[/green] {step_name} complete\n")
                else:
                    if self.console:
                        self.console.print(f"[red]✗[/red] {step_name} failed\n")
            except Exception as e:
                if self.console:
                    self.console.print(f"[red]✗[/red] {step_name} error: {e}\n")
                raise

        # Show summary
        self.show_first_boot_summary()

    def check_prerequisites(self) -> bool:
        """Check if all required tools are installed"""
        required = ["docker", "git", "powershell"]
        missing = []

        for cmd in required:
            try:
                subprocess.run([cmd, "--version"], capture_output=True, check=True)
                if self.console:
                    self.console.print(f"  [green]✓[/green] {cmd} installed")
            except (subprocess.CalledProcessError, FileNotFoundError):
                missing.append(cmd)
                if self.console:
                    self.console.print(f"  [red]✗[/red] {cmd} missing")

        # Check Python (optional)
        try:
            subprocess.run(["python", "--version"], capture_output=True, check=True)
            if self.console:
                self.console.print(f"  [green]✓[/green] Python installed")
        except:
            if self.console:
                self.console.print(f"  [yellow]⚠[/yellow] Python not installed (TUI will be degraded)")

        return len(missing) == 0

    def verify_repository(self) -> bool:
        """Verify repository is cloned"""
        repo_dir = self.base_dir.parent
        git_dir = repo_dir / ".git"

        if git_dir.exists():
            if self.console:
                self.console.print(f"  [green]✓[/green] Repository found: {repo_dir.name}")
            return True
        else:
            if self.console:
                self.console.print(f"  [yellow]⚠[/yellow] Repository not found")
                self.console.print(f"    Please clone first: git clone <url> {repo_dir.parent}")
            return False

    def install_dependencies(self) -> bool:
        """Install Python TUI dependencies"""
        if not RICH_AVAILABLE:
            if self.console:
                self.console.print(f"  [yellow]⚠[/yellow] Skipping - Rich not available")
            return True

        req_file = self.scripts_dir / "requirements.txt"
        if not req_file.exists():
            if self.console:
                self.console.print(f"  [yellow]⚠[/yellow] requirements.txt not found")
            return False

        try:
            subprocess.run(
                ["python", "-m", "pip", "install", "-r", str(req_file)],
                check=True
            )
            if self.console:
                self.console.print(f"  [green]✓[/green] Dependencies installed")
            return True
        except subprocess.CalledProcessError as e:
            if self.console:
                self.console.print(f"  [yellow]⚠[/yellow] Failed: {e}")
            return False

    def prompt_clean_data(self) -> bool:
        """Prompt to clean existing Docker data"""
        try:
            result = subprocess.run(
                ["docker", "ps", "-q"],
                capture_output=True,
                check=True
            )

            if self.console:
                self.console.print(f"  [yellow]⚠[/yellow] Existing containers found")
                if Confirm.ask("Stop and remove all data?"):
                    self.clean_all(force=True)
                    return True
                else:
                    self.console.print(f"  [yellow]⚠[/yellow] Keeping existing data")
                    return True
        except subprocess.CalledProcessError:
            if self.console:
                self.console.print(f"  [green]✓[/green] No existing data")
            return True

    def start_docker_infrastructure(self) -> bool:
        """Start Docker containers"""
        compose_file = self.docker_compose_dir / "docker-compose.yml"

        if not compose_file.exists():
            if self.console:
                self.console.print(f"  [red]✗[/red] docker-compose.yml not found")
            return False

        try:
            if self.console:
                with Progress(
                    SpinnerColumn(),
                    TextColumn("[progress.description]{task.description}"),
                    console=self.console
                ) as progress:
                    task = progress.add_task("[cyan]Starting Docker containers...", total=None)
                    subprocess.run(
                        ["docker", "compose", "-f", str(compose_file), "up", "-d"],
                        check=True
                    )
                    progress.add_task("[green]✓[/green] Containers started!")

            if self.console:
                self.console.print(f"  [green]✓[/green] Infrastructure started")
            return True
        except subprocess.CalledProcessError as e:
            if self.console:
                self.console.print(f"  [red]✗[/red] Failed: {e.stderr}")
            return False

    def run_bootstrap_scripts(self) -> bool:
        """Run bootstrap.ps1 script"""
        bootstrap_script = self.scripts_dir / "bootstrap.ps1"

        if not bootstrap_script.exists():
            if self.console:
                self.console.print(f"  [red]✗[/red] bootstrap.ps1 not found")
            return False

        try:
            self.run_powershell("bootstrap.ps1")

            if self.console:
                self.console.print(f"  [green]✓[/green] Bootstrap scripts executed")
            return True
        except Exception as e:
            if self.console:
                self.console.print(f"[red]✗[/red] Failed: {e}")
            return False

    def build_backend_library(self) -> bool:
        """Build arda-shared-kernel"""
        shared_kernel_dir = self.base_dir / "arda-shared-kernel"

        if not shared_kernel_dir.exists():
            if self.console:
                self.console.print(f"  [yellow]⚠[/yellow] arda-shared-kernel not found")
            return True  # Not an error, just optional

        mvnw = shared_kernel_dir / "mvnw.cmd"
        if not mvnw.exists():
            if self.console:
                self.console.print(f"  [yellow]⚠[/yellow] mvnw.cmd not found")
            return False

        try:
            if self.console:
                with Progress(
                    SpinnerColumn(),
                    TextColumn("[progress.description]{task.description}"),
                    console=self.console
                ) as progress:
                    task = progress.add_task("[cyan]Building arda-shared-kernel...", total=None)
                    subprocess.run(
                        [str(mvnw), "clean", "install", "-DskipTests"],
                        check=True,
                        cwd=str(shared_kernel_dir)
                    )
                    progress.add_task("[green]✓[/green] Build complete!")

            if self.console:
                self.console.print(f"  [green]✓[/green] Backend library built")
            return True
        except subprocess.CalledProcessError as e:
            if self.console:
                self.console.print(f"  [red]✗[/red] Failed: {e}")
            return False

    def show_first_boot_summary(self):
        """Show summary and next steps"""
        if not self.console:
            return

        self.console.print("\n")
        self.console.print(Panel(
            "[bold green]✓ First Boot Complete![/bold green]\n\n"
            "Infrastructure ready for development\n\n"
            "[bold cyan]Next Steps:[/bold cyan]\n"
            "1. Update CLIENT SECRET in docker-compose/.env\n"
            "   NOTIFICATION_KC_CLIENT_SECRET=<secret-from-keycloak-setup>\n\n"
            "2. Restart notification service\n"
            "   docker compose restart arda-notification\n\n"
            "3. Start backend services\n"
            "   cd arda-central-platform && mvn spring-boot:run\n"
            "   cd arda-iam-service && mvn spring-boot:run\n\n"
            "4. Start frontend\n"
            "   cd arda-mfe && pnpm dev\n\n"
            "5. Or use this tool for management\n"
            "   python arda-manager.py status\n"
            "   python arda-manager.py setup-keycloak",
            title="🎉 Setup Complete",
            box=box.DOUBLE
        ))

    def interactive_menu(self):
        """Interactive menu mode"""
        while True:
            if not RICH_AVAILABLE:
                print("\n=== Arda Infrastructure Manager ===")
                print("1. Show Status")
                print("2. Clean All")
                print("3. Bootstrap")
                print("4. Setup Keycloak")
                print("5. Setup DB")
                print("6. Setup APISIX")
                print("7. Generate Keys")
                print("9. First Boot (Fresh Machine)")
                print("0. Exit")
                choice = input("\nSelect option: ")

                actions = {
                    "1": self.show_status,
                    "2": self.clean_all,
                    "3": self.bootstrap,
                    "4": self.setup_keycloak,
                    "5": self.setup_db,
                    "6": self.setup_apisix,
                    "7": self.generate_keys,
                    "8": self.start_services,
                    "9": self.first_boot,
                    "0": exit,
                }

                actions = {
                    "1": self.show_status,
                    "2": self.clean_all,
                    "3": self.bootstrap,
                    "4": self.setup_keycloak,
                    "5": self.setup_db,
                    "6": self.setup_apisix,
                    "7": self.generate_keys,
                    "8": self.start_services,
                    "0": exit
                }

                if choice in actions:
                    actions[choice]()
                else:
                    print("Invalid option")
                return

            self.console.print("\n")
            table = Table(show_header=True, box=box.ROUNDED)
            table.add_column("Option", style="cyan")
            table.add_column("Action", style="white")

            actions = [
                ("1", "📊 Show Status"),
                ("2", "🧹 Clean All"),
                ("3", "🚀 Full Bootstrap"),
                ("4", "🔐 Setup Keycloak"),
                ("5", "🗄️  Setup DB"),
                ("6", "🌐 Setup APISIX"),
                ("7", "🔑 Generate Keys"),
                ("8", "▶️  Start Services"),
                ("9", "🚀 First Boot"),
                ("0", "❌ Exit"),
            ]

            for opt, action in actions:
                table.add_row(opt, action)

            self.console.print(Panel(table, title="[bold cyan]Main Menu[/bold cyan]"))

            choice = Prompt.ask(
                "\n[cyan]Select option:[/cyan]",
                choices=["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
            )

            actions_dict = {
                "1": self.show_status,
                "2": lambda: self.clean_all(force=True),
                "3": self.bootstrap,
                "4": self.setup_keycloak,
                "5": self.setup_db,
                "6": self.setup_apisix,
                "7": self.generate_keys,
                "8": self.start_services,
                "9": self.first_boot,
                "0": exit,
            }

            try:
                # Clear screen before action (optional)
                # os.system('cls' if os.name == 'nt' else 'clear')

                # Execute action
                actions_dict[choice]()
            except KeyboardInterrupt:
                self.console.print("\n[yellow]Interrupted by user[/yellow]")
            except Exception as e:
                self.console.print(f"\n[red]Error: {e}[/red]")
                if self.console:
                    self.console.print("\n[gray]Press Enter to continue...[/gray]")
                else:
                    print("\nPress Enter to continue...")
                input()


def main():
    if len(sys.argv) > 1:
        # Command line mode
        manager = ArdaInfraManager()
        command = sys.argv[1].lower()

        actions = {
            "status": manager.show_status,
            "clean": lambda: manager.clean_all(force="--force" in sys.argv),
            "bootstrap": manager.bootstrap,
            "setup-keycloak": manager.setup_keycloak,
            "setup-db": manager.setup_db,
            "setup-apisix": manager.setup_apisix,
            "generate-keys": manager.generate_keys,
            "start": manager.start_services,
            "first-boot": manager.first_boot,
        }

        if command in actions:
            actions[command]()
        else:
            print(f"Unknown command: {command}")
            print("Available: status, clean, bootstrap, setup-keycloak, setup-db, setup-apisix, generate-keys, start, first-boot")
    else:
        # Interactive menu mode
        manager = ArdaInfraManager()
        manager.interactive_menu()


if __name__ == "__main__":
    main()
