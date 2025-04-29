# gleamstrom

[![Package Version](https://img.shields.io/hexpm/v/gleamstrom)](https://hex.pm/packages/gleamstrom)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/gleamstrom/)

```sh
gleam add gleamstrom
```

```gleam
import gleamstrom

pub fn main() -> Nil {
  let assert Ok(_) = gleamstrom.start_node(app_state, request_handler)
}
```

Further documentation can be found at <https://hexdocs.pm/gleamstrom>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```
