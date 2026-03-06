# Opal 2

Remotely access all your agents, everywhere, on any machine.

## Project Structure

opal/ <- Core elixir agent library
daemon/ <- Simple daemon that connects opal to the relay server, using an encrypted handshake, securely tunneling websocket events, hosts a communication protocol
relay/ <- thin secure relay in elixir that tunnels messages
ui/ <- Simple Vite SPA, with client library for the daemon's protocol using state management

## Features

- Managing multiple clients, seeing their online/offline status
- Seeing running sessions and their status/metadata
- Start/stop/restart sessions
- Live stream session events
- Fire prompts and steers
