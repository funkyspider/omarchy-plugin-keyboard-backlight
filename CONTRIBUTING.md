# Contributing

Issues and pull requests are welcome.

Before submitting a change, run:

```bash
bash -n bin/keyboard-backlight
python3 -m json.tool manifest.json >/dev/null
python3 -m unittest discover -s tests -v
```

Keep the plugin event-driven. Changes should not introduce a permanent polling timer or require elevated privileges.
