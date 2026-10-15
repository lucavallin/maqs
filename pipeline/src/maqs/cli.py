"""Command-line entry point. Commands are wired to real work in later tasks."""

import click


@click.group()
@click.version_option(package_name="maqs")
def main() -> None:
    """Build and inspect maqs data packs."""


@main.command()
def build() -> None:
    """Build layers for a region."""
    raise click.ClickException("not implemented yet")


@main.command()
def regions() -> None:
    """List configured regions."""
    raise click.ClickException("not implemented yet")


@main.command("check-tools")
def check_tools() -> None:
    """Verify the pinned external tools are installed."""
    raise click.ClickException("not implemented yet")
