# Mail Surgeon Manual UI QA

Mail Surgeon remains read-only by default. Loading, indexing, recovery scanning, and export planning must not modify the source mailbox. Recovery exports write only after the user selects a destination in a save panel.

## Build and launch

```bash
make app
make run
```

Do not use `swift run MailSurgeon` for GUI acceptance testing.

## Source hash verification

Before interactive mailbox QA, record the source mailbox SHA-256:

```bash
shasum -a 256 /path/to/source.mbox
```

After all search, recovery, export, attachment-save, and source-selection tests, run the same command again:

```bash
shasum -a 256 /path/to/source.mbox
```

The source hash must be identical before and after the full sequence. Do not paste private mailbox paths into commits, tests, screenshots, or issue comments unless the owner explicitly approves it.

## Unified logging

Run unified logging in a separate terminal while performing manual QA:

```bash
log stream --style compact --predicate 'process == "MailSurgeon"'
```

Debug builds emit privacy-safe `UIActions` events for queued/completed menu commands, source open panels, save panels, and useful List selection boundaries. These events use generic command names only. They must not include sender names, email addresses, subjects, message bodies, attachment names, filesystem paths, recovery evidence, raw headers, or sensitive metadata.

If an AppKit warning appears, record the exact immediately preceding `UIActions` log entry and the visible interaction that triggered it.

## Checklist

### Application

1. App appears in Dock.
2. One main window opens.
3. Window is usable at 900 x 620.
4. Window is usable at 1180 x 760.
5. No essential controls are outside the visible area.

### Messages

6. Select an MBOX source.
7. Load messages.
8. Open and close the message filter menu without selecting anything.
9. Enable one message filter.
10. Clear message filters.
11. Select at least three different message sort modes.
12. Click search.
13. Type text continuously.
14. Search retains keyboard focus.
15. Results update after debounce.
16. Clearing search restores results.
17. Selecting several messages opens the inspector and does not reset search focus.
18. Show and hide the message inspector.
19. Paging works when indexed results exceed one page.

### Recovery

20. Start Recovery Dry Run.
21. Progress updates.
22. Cancel works safely.
23. Let one scan complete if practical.
24. Completed report shows issue summary.
25. Recovery search works with continuous typing.
26. Severity filtering changes the issue list.
27. Clearing recovery filters works.
28. Issue-type filtering changes the issue list.
29. Selecting several issues opens the inspector without destabilizing the list.

### Export

30. Switch to Export.
31. Open and cancel JSON save panel.
32. Open and complete JSON save panel.
33. Open and cancel Markdown save panel.
34. Open and complete Markdown save panel.
35. Open and cancel Preserve All recovered MBOX export.
36. Open and complete Preserve All recovered MBOX export.
37. Open and cancel Deduplicated recovered MBOX export.
38. Open and complete Deduplicated recovered MBOX export.
39. Open and cancel Recoverable Only recovered MBOX export.
40. Open and complete Recoverable Only recovered MBOX export.
41. Open and cancel attachment save if an attachment is available.
42. Cancelling any save panel is non-error behavior: it may update status, but must not show an error.
43. Export errors are visible.
44. Repeated clicks while a save panel is open must not open duplicate panels.
45. Source MBOX SHA-256 is unchanged.

### Source addition

46. Open Add Source menu.
47. Select MBOX and cancel the open panel.
48. Cancellation is non-error behavior and creates no source.
49. Select MBOX again and complete the open panel.
50. Exactly one new source is created.
51. Source selection updates only after the open panel completes.
52. Switch between Messages, Recovery, and Export several times.
53. Quit the application.

## Runtime warnings

Run the application through `make run` and inspect unified logs during:

- popup-menu open/close
- message filter changes
- message sort changes
- source addition
- search typing
- list selection
- recovery severity/type filtering
- recovery issue selection
- save/open panel cancellation and completion

This warning must not appear:

```text
Application performed a reentrant operation in its NSTableView delegate.
```

These warnings must also not appear:

```text
deferral block timed out
deferral block executed twice
```

If any warning appears, do not suppress it. Record the exact preceding `UIActions` log entry, the interaction that triggered it, and whether the warning followed a popup-menu command, List selection, open panel, or save panel.

## Known limitations

- Keyboard focus and visible layout are manual QA items; unit tests do not validate them.
- HTML, scripts, and arbitrary remote message content are not loaded in the inspector.
- Recovery exports require an explicit save-panel destination and never repair the source mailbox in place.
