from __future__ import annotations

from gateway.run import _prepare_gateway_status_message


def test_noisy_compression_status_suppressed_for_discord():
    assert (
        _prepare_gateway_status_message(
            "discord",
            "compaction",
            "🧲 Compacting context — summarizing earlier conversation so I can continue...",
        )
        is None
    )


def test_noisy_compression_status_suppressed_for_telegram():
    assert (
        _prepare_gateway_status_message(
            "telegram",
            "compaction",
            "🧲 Compacting context — summarizing earlier conversation so I can continue...",
        )
        is None
    )


def test_normal_status_still_delivered():
    assert (
        _prepare_gateway_status_message("discord", "status", "Working on the Lowe's quote")
        == "Working on the Lowe's quote"
    )
