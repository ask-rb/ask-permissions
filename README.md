# Ask::Permissions

Shared permission rules and approval workflows for the [ask-rb](https://github.com/ask-rb) ecosystem.

`ask-permissions` is the reusable policy layer for deciding whether a tool call may proceed, must be denied, or requires human approval. It is independent of agent sessions and protocols; integrations provide callbacks for applying or rejecting approved actions.

## Installation

```ruby
gem "ask-permissions"
```

## Development

```sh
bundle install
bundle exec rake test
```

## License

MIT. See [LICENSE](LICENSE).
