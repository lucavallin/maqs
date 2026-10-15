from click.testing import CliRunner

from maqs.cli import main


def test_help_lists_commands():
    result = CliRunner().invoke(main, ["--help"])
    assert result.exit_code == 0
    for command in ("build", "regions", "check-tools"):
        assert command in result.output
