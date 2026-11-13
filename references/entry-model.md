# Entry model and reference resolution

## Why references

Copying a credential into a second entry creates a rotation trap: the copy keeps
working until someone rotates the original, then the agent fails with a 401 nobody
attributes to the vault. A reference entry holds no secret; it names where the
secret lives.

## Shapes

Literal entry (the value exists only here):

```
Group:    hermes
Title:    FOO_API_KEY
Password: <the secret>
URL:
```

Reference entry (the value already lives elsewhere in the database):

```
Group:    hermes
Title:    FOO_API_KEY
Password:              # left blank
URL:      ref:Infrastructure/gateway
```

Optional field selector: `ref:Mail/smtp#Username`, `ref:Notes/ssh#Notes`. Field names
are the CSV column names (`Password`, `Username`, `URL`, `Notes`), matched
case-insensitively.

## Resolution rules

1. Split off `#<Field>`; default `Password`.
2. Split the path on `/`; components are matched against the entry's
   **root-relative** path (the database's own root group segment is dropped).
3. Exact match wins.
4. Otherwise a case-insensitive trailing-component match is attempted; exactly one
   hit is accepted, several produce `ambiguous` and the entry is skipped.
5. A missing entry, a missing field, an empty value, or a value spanning lines all
   skip that one var with a stderr note. Never guess.

## Group scoping

`keepassxc-cli export -f csv` writes the full group path, root group included:

```
"Group","Title","Username","Password","URL","Notes","TOTP","Icon","Last Modified","Created"
"Vault/hermes","FOO_API_KEY","","","ref:Infrastructure/gateway","","",...
"Vault/hermes/sub","BAR_TOKEN","","","","","",...
"Vault/Unrelated/hermes","DECOY","","","","","",...
```

Correct filter: drop segment 0, then prefix-match the configured group name.

```python
def in_group(grp):
    rel = grp[1:]
    return rel[:len(want)] == want
```

The tempting version — "is `hermes` anywhere in the path?" — also matches
`Vault/Unrelated/hermes`, which turns any future group with the same name into an
injection surface. It was reproduced: one decoy entry in an unrelated `hermes`
group was emitted as a live env var.

## CSV mechanics worth knowing

- One `export` per run: the KDF (Argon2 or similar) dominates, so reopening per
  entry is what blows a startup timeout.
- Parse with a real CSV reader — unquoted splitting breaks on commas and quotes.
- Header is `Group,Title,Username,Password,URL,Notes,TOTP,Icon,Last Modified,Created`.
- Entries with an empty Password and no `ref:` are skipped silently by design, which
  is also how you "disable" an entry without deleting it.
