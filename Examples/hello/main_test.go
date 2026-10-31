package main

import "testing"

func TestGreet(t *testing.T) {
	if got, want := greet("gopher"), "Hello, gopher!"; got != want {
		t.Errorf("greet() = %q, want %q", got, want)
	}
}
