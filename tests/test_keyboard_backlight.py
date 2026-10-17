import os
import pathlib
import stat
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "bin" / "keyboard-backlight"


class KeyboardBacklightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.sysfs = self.root / "leds"
        self.state = self.root / "state"
        self.bin = self.root / "bin"
        self.sysfs.mkdir()
        self.bin.mkdir()

        self.fake_brightnessctl = self.bin / "brightnessctl"
        self.fake_brightnessctl.write_text(
            """#!/usr/bin/env bash
set -eu
[[ ${1:-} == -q ]] && shift
[[ ${1:-} == -d ]] || exit 64
device=$2
shift 2
[[ ${1:-} == set ]] || exit 64
printf '%s\n' "$2" > "$FAKE_SYSFS_ROOT/$device/brightness"
""",
            encoding="utf-8",
        )
        self.fake_brightnessctl.chmod(0o755)

        self.env = os.environ.copy()
        self.env.update(
            {
                "KEYBOARD_BACKLIGHT_SYSFS_ROOT": str(self.sysfs),
                "KEYBOARD_BACKLIGHT_STATE_HOME": str(self.state),
                "BRIGHTNESSCTL": str(self.fake_brightnessctl),
                "FAKE_SYSFS_ROOT": str(self.sysfs),
            }
        )

    def add_device(self, name="test::kbd_backlight", brightness=128, maximum=255):
        device = self.sysfs / name
        device.mkdir()
        (device / "brightness").write_text(f"{brightness}\n", encoding="utf-8")
        (device / "max_brightness").write_text(f"{maximum}\n", encoding="utf-8")
        return device

    def run_helper(self, *arguments, check=True, env=None):
        command = [str(HELPER), *(arguments or ("status",))]
        return subprocess.run(
            command,
            env=self.env if env is None else env,
            check=check,
            text=True,
            capture_output=True,
            timeout=3,
        )

    @staticmethod
    def brightness(device):
        return int((device / "brightness").read_text(encoding="utf-8").strip())

    def test_status_auto_detects_device(self):
        self.add_device(brightness=179)
        result = self.run_helper("status")
        self.assertEqual(result.stdout, "available\ttest::kbd_backlight\t179\t255\t70\n")

    def test_status_reports_unavailable_without_device(self):
        result = self.run_helper("status", check=False)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(result.stdout, "unavailable\n")

    def test_explicit_device_wins_over_auto_detection(self):
        self.add_device(name="alpha::kbd_backlight", brightness=1, maximum=3)
        self.add_device(name="chosen::kbd_backlight", brightness=3, maximum=4)
        result = self.run_helper("status", "chosen::kbd_backlight")
        self.assertIn("available\tchosen::kbd_backlight\t3\t4\t75", result.stdout)

    def test_set_converts_percentage_to_hardware_value(self):
        device = self.add_device(brightness=0)
        result = self.run_helper("set", "70")
        self.assertEqual(self.brightness(device), 179)
        self.assertTrue(result.stdout.endswith("\t70\n"))

    def test_set_rejects_invalid_percentage(self):
        device = self.add_device(brightness=128)
        result = self.run_helper("set", "101", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.brightness(device), 128)

    def test_up_and_down_use_hardware_aware_steps(self):
        device = self.add_device(brightness=1, maximum=3)
        self.run_helper("up")
        self.assertEqual(self.brightness(device), 2)
        self.run_helper("down")
        self.assertEqual(self.brightness(device), 1)

    def test_toggle_restores_previous_nonzero_value(self):
        device = self.add_device(brightness=179)
        self.run_helper("toggle")
        self.assertEqual(self.brightness(device), 0)
        self.run_helper("toggle")
        self.assertEqual(self.brightness(device), 179)

    def test_toggle_from_off_defaults_to_maximum(self):
        device = self.add_device(brightness=0)
        self.run_helper("toggle")
        self.assertEqual(self.brightness(device), 255)

    def test_repeated_off_preserves_last_nonzero_value(self):
        device = self.add_device(brightness=128)
        self.run_helper("off")
        self.run_helper("off")
        self.run_helper("toggle")
        self.assertEqual(self.brightness(device), 128)

    def test_state_directory_and_file_are_private(self):
        self.add_device(brightness=128)
        self.run_helper("off")
        state_file = self.state / "test__kbd_backlight"
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(state_file.stat().st_mode), 0o600)

    def test_symlink_state_directory_is_rejected_before_turning_off(self):
        device = self.add_device(brightness=128)
        actual_state = self.root / "actual-state"
        actual_state.mkdir()
        self.state.symlink_to(actual_state, target_is_directory=True)
        result = self.run_helper("off", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.brightness(device), 128)

    def test_off_fails_safely_without_a_state_directory(self):
        device = self.add_device(brightness=128)
        env = self.env.copy()
        for name in ("KEYBOARD_BACKLIGHT_STATE_HOME", "XDG_STATE_HOME", "HOME"):
            env.pop(name, None)
        result = self.run_helper("off", check=False, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.brightness(device), 128)


if __name__ == "__main__":
    unittest.main()
