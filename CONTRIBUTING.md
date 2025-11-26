# Contributing to Dartus

## Development Setup

```bash
# Clone repository
git clone https://github.com/Immadominion/Dartus.git
cd Dartus

# Install dependencies
dart pub get

# Run tests
dart test

# Run analyzer
dart analyze

# Format code
dart format .
```

## Running Tests

```bash
# All tests (unit + integration)
dart test

# Specific test file
dart test test/blob_cache_test.dart

# With verbose output
dart test --reporter expanded
```

## Code Style

- Follow [Effective Dart](https://dart.dev/effective-dart) guidelines
- Run `dart format .` before committing
- Ensure `dart analyze` reports no issues
- Maintain test coverage above 70%

## Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes with tests
4. Run `dart test`, `dart analyze`, `dart format .`
5. Commit with clear messages
6. Push and create a pull request

## Testing Guidelines

- Add unit tests for new functionality
- Keep integration tests minimal (network costs)
- Mock external dependencies where possible
- Verify tests pass locally before pushing
