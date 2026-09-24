# Contributing to CROS Debian Assistant

Thanks for helping improve CROS.

## Start with a clean clone

    git clone https://github.com/chasespringerlr-web/Cros_Debian_Assistant.git
    cd Cros_Debian_Assistant

## Core development

The CROS core installer is:

    core/cros_debian_assistant_v24.sh

Test core changes from a clean Debian/ChromeOS environment when practical.

## Plugin development

Plugins live under:

    plugins/

The completed official plugins currently included in the public release are listed in the README.

Keep new plugins inline with the CROS UI and preserve the plugin manifest/entry-point convention used by the existing plugins.

## Testing

Prefer small, reproducible fixtures for hardware and CAD-related functionality. Do not add credentials, private keys, API tokens, or other secrets to the repository.

## Pull requests

Please describe:
- what changed
- how it was tested
- any Debian/ChromeOS assumptions
- any new files or fixtures needed to reproduce the test

