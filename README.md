# Spamurai

<img src="Resources/icon.png" width="96" alt="">

Spamurai is a Mac app that notices robocalls and spam texts to your iPhone and files the FCC complaint for you.

Your iPhone already syncs its calls and messages to your Mac. When a number that is not in your
contacts, and that you have never called or written to, rings or texts your phone, Spamurai looks up
how many FCC complaints already name that number, then either files a complaint or asks you first.

![The Calls window](docs/calls.png)

## What you need

- A Mac (macOS 14 or later, Apple silicon or Intel) and an iPhone signed in to the same Apple Account,
  so calls sync to the Mac
- A US phone number: complaints go to the FCC

## Install

1. Download `Spamurai-2.0.dmg` from the [Releases page](https://github.com/rkoh46/spamurai/releases).
2. Open it and drag Spamurai to Applications.
3. Open Spamurai. It is not signed with a paid Apple developer certificate, so the first time macOS
   says it cannot verify the app: open System Settings, Privacy & Security, scroll down and press
   **Open Anyway**.

The app opens on its Setup page, with a checklist at the top:

1. **Your details.** The FCC requires a name, address, email and phone number on every complaint.
2. **Your answers about the calls.** The form asks what kind of call it was. You choose the answers once.
3. **How Spamurai asks you.** An iMessage to yourself (reply `1` to file, `2` to ignore), a
   notification on the Mac with File and Ignore buttons, or nothing at all: callers it is unsure about
   then wait on the Calls page until you file or ignore them there. For iMessage, send yourself one
   message from the Mac first; Setup has a button for it. **Send a Test Question** proves the round
   trip without filing anything.
4. **Access to your calls.** macOS only lets apps with Full Disk Access read the call log and your
   replies in Messages. Setup opens the right list; switch Spamurai on, then quit and reopen it.

Spamurai keeps watching from the menu bar after you close its window. Setup has a switch to open it
when you log in.

![Setup](docs/setup.png)

### Build it yourself

With Xcode installed:

    git clone https://github.com/rkoh46/spamurai.git
    cd spamurai
    ./build.sh
    open ~/Applications/Spamurai.app

`./release.sh 2.0` makes the DMG in `dist/`.

## How it decides

- **Likely robocall or spam text:** the FCC already has 3 or more complaints on the number, your
  carrier labels the call as spam, or your iPhone marked the text as junk. You can let these be filed
  without asking (off by default).
- **Texts:** only texts from ordinary 10 digit numbers are handled. Short codes and email senders are
  left alone, and so are sign-in codes. The FCC form takes no attachments, so the complaint quotes
  what the message said.
- **Unsure:** you are asked. File the complaint, or ignore the number so it never asks again.
- **Likely, with automatic filing on:** you are told when it will be filed (30 minutes later by
  default). Ignore the number in that time to stop it. A call you talked on for 30 seconds or more is
  always asked about instead.
- People in your contacts, numbers you have called, and numbers you ignored are never reported.

## Read this before you turn it on

- **Each complaint is a sworn statement.** The FCC form ends with a declaration under penalty of
  perjury. Spamurai files with the answers you chose in Setup, so choose answers that are true for
  the calls you report, and think before letting it file calls you never heard.
- **Caller ID is often faked.** The number on your screen may belong to someone innocent.
- **The FCC does not act on single complaints.** It uses them in bulk to pick enforcement targets.
  Filing will not stop the calls by itself.
- Spamurai files at most 5 complaints an hour.

## How it files

Spamurai opens the FCC's own complaint form in a web view (the same engine as Safari), with the call's
date, time and number filled in through the form's address, types in your details, ticks the
attestation box and presses Submit. If the site shows a check that needs a person, filing stops and the
app tells you; "Show Form" in the app shows the page.

## Privacy

Everything stays on your Mac: settings in `~/Library/Application Support/Spamurai/config.json`,
history in `state.db` next to it. Spamurai talks to three places: the FCC's public complaint data (to
look up a caller's number), the FCC complaint site (to file, with your details), and Messages on this
Mac when you chose iMessage (the questions go to your own address through Apple).

## Code

- `Sources/Core.swift`: the synced call log, Messages history and Contacts (all read-only), history, FCC complaint counts
- `Sources/Engine.swift`: the watch loop, scoring, asking and filing
- `Sources/Filer.swift`: the FCC form in a web view
- `Sources/Notifier.swift`: iMessage to yourself (replies are read from the Mac's Messages history) and Mac notifications
- `Sources/Views.swift`, `App.swift`, `Settings.swift`: the window, menu bar item and settings

`SPAMURAI_DEMO=<folder>` runs the app on the `config.json` and `state.db` in that folder without
watching anything. `SPAMURAI_FILL_TEST=1` fills the real FCC form for a made-up call, does not send it,
prints the result and quits.

## Uninstall

    ./uninstall.sh          # keeps your settings and history
    ./uninstall.sh --all    # removes those too

## License

MIT. Spamurai is not affiliated with the FCC.
