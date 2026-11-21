# :real_just runs this project's own justfile for real, which shells out to
# `mix test`; included by default it would call itself forever.
# Only a failing test prints its log: the tail of the output is what the loop hands a coder.
Code.require_file("support/tellings.exs", __DIR__)
ExUnit.start(exclude: [:real_just], capture_log: true)
