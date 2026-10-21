# Documentation

This directory indexes repository-native documentation for `core`.

## Areas

- `Architecture/`: current truth for package structure and documentation
  placement
- `Proposals/`: design-in-progress and open alternatives
- `Decisions/`: accepted decisions and rationale
- `Migrations/`: transition and cutover records
- `Archive/`: retired or superseded material kept for record
- `Reference/`: supporting reference material and examples, including
  [presentation reproduction](Reference/Presentation.md)

The [README logos](../.github/assets/logo/) are generated from the `core` entry
in [the organization DESIGN][design]. The committed
[social preview](../.github/assets/social-preview/social-preview.png) uses the
same logo and the catalog at the pinned presentation standard.

Target-level API documentation belongs with the SwiftPM target it documents,
normally under `Sources/<Target>/<Target>.docc/`. Link to those catalogs from
this index when present, but do not move them under `Documentation/` by
default.

## Placement Rules

- Put current canonical guidance in `Architecture/`.
- Put unresolved changes and alternatives in `Proposals/`.
- Put historical records in `Decisions/`, `Migrations/`, and `Archive/`.
- Put supporting reference material in `Reference/`.
- Keep DocC catalogs with their SwiftPM targets.
- Keep GitHub-facing workflow metadata in `.github/`; community files and
  templates use the organization defaults in `agents-tools/.github`.

[design]: https://github.com/agents-tools/.github/blob/master/DESIGN.md
