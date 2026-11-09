# SlowQuit licensing and acknowledgements

SlowQuit — Copyright (C) 2026 SlowQuit contributors.

SlowQuit is distributed under the GNU General Public License, version 2 or
(at your option) any later version. See the accompanying `LICENSE`.

## SlowQuitApps

Source: https://github.com/dteoh/SlowQuitApps

Reference revision: `2c75877c633f5918bdca20e3b3046318632e0d80`.

Copyright (C) 2020 Douglas Teoh.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License along
with this program; if not, write to the Free Software Foundation, Inc.,
51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

### Adaptation, 2026-09-28

`SlowQuit/QuitProtectionService.swift` adapts the event-tap interception,
Command-Tab tracking, application exclusion and normal-termination approach
from `SlowQuitApps/SQAAppDelegate.m` into Swift. The new implementation uses
a monotonic timer rather than key repeat, captures the target application,
suppresses the intercepted Q sequence, cancels on focus/session changes,
and monitors Accessibility, Secure Input and event-tap health.

The Swift state machine, dual-mode preferences, short-press statistics,
Accessibility menu classification, tagged key replay, original vector Q icon,
SwiftUI settings, progress overlay and `SMAppService` login integration are
new implementation work.
The original app icon and other upstream graphical assets are not included.

When distributing the app, also make the complete corresponding source,
including the Xcode project, available under the license's terms.
