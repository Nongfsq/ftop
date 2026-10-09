# Contributing to ftop

ftop is a small project with one maintainer who decides what the panel shows and how
it looks. These rules keep the issue list about ftop and nothing else.

## Issues

Use one of the two forms. Blank issues are turned off.

**Something is wrong.** A reading is missing or wrong, or the panel misbehaves. The
form asks for your ftop version, your Mac and macOS, and the full output of
`ftop doctor` (or `ftop doctor --states` for a missing frequency). Update to the
latest release first. Reports from a chip ftop has not seen are the most useful
thing you can send.

**Suggestion.** Describe what you were trying to see or do before describing a
solution. Most suggestions are declined, because of what ftop is:

- It shows current state only: no history graphs, no disk panels.
- It keeps text to a minimum; detail belongs in the hover.
- It stays usable at every window size, so anything added to the panel takes room
  from something else.
- It supports Apple Silicon and macOS 15 or later.
- It is installed from the release page or from source. There is no Homebrew formula
  or cask, and the README does not link to third-party packages.

An issue is closed without a reply, and may be locked or deleted, when it is:

- an advertisement, an invitation, a request to list or promote ftop somewhere, or
  anything else that is not about ftop;
- filed without the form, or with the required fields left empty or filled with
  placeholders;
- a duplicate of an open or closed issue;
- a question that the README answers.

Accounts that post advertisements are blocked.

## Pull requests

Pull requests from outside the project are not accepted, and the repository does not
allow them to be opened. What the panel shows and how it is laid out are decided in
one place, and a change that arrives without that discussion nearly always has to be
redone.

If you want something changed, open an issue. If you have already written code,
link your branch in the issue; it can be read there.
