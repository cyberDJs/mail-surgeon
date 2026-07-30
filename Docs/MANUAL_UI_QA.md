# Mail Surgeon Manual UI QA

Mail Surgeon remains read-only by default. Loading, indexing, recovery scanning, and export planning must not modify the source mailbox. Recovery exports write only after the user selects a destination in a save panel.

## Build and launch

```bash
make app
make run
```

Do not use `swift run MailSurgeon` for GUI acceptance testing.

## Source hash verification

Before an export:

```bash
shasum -a 256 /path/to/source.mbox
```

After every report or MBOX export:

```bash
shasum -a 256 /path/to/source.mbox
```

The source hash must be identical before and after the operation.

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
8. Click search.
9. Type text continuously.
10. Search retains keyboard focus.
11. Results update after debounce.
12. Clearing search restores results.
13. Filter menu changes results.
14. Sort menu changes order.
15. Selecting a message opens the inspector.
16. Changing message selection does not reset search focus.
17. Paging works when indexed results exceed one page.

### Recovery

18. Start Recovery Dry Run.
19. Progress updates.
20. Cancel works safely.
21. Completed report shows issue summary.
22. Recovery search works.
23. Severity/type filtering works.
24. Selecting an issue opens the inspector.

### Export

25. JSON export opens a save panel and creates a file.
26. Markdown export opens a save panel and creates a file.
27. Preserve All MBOX export creates a file.
28. Deduplicated MBOX export creates a file.
29. Recoverable Only MBOX export creates a file.
30. Cancelling any save panel is harmless.
31. Export errors are visible.
32. Source MBOX SHA-256 is unchanged.

### Runtime warning

Run the application from Terminal through `make run` and inspect logs during:

- search typing
- list selection
- sort changes
- recovery issue selection

This warning must not appear:

```text
Application performed a reentrant operation in its NSTableView delegate.
```

If it appears, record the exact interaction that triggered it and inspect List selection orchestration for synchronous model mutations.

## Known limitations

- Keyboard focus and visible layout are manual QA items; unit tests do not validate them.
- HTML, scripts, and arbitrary remote message content are not loaded in the inspector.
- Recovery exports require an explicit save-panel destination and never repair the source mailbox in place.
