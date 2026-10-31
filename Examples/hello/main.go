package main

import "fmt"

// greet returns a friendly greeting.
func greet(name string) string {
	return fmt.Sprintf("Hello, %s!", name)
}

func main() {
	for i, name := range []string{"gopher", "swift"} {
		fmt.Println(i, greet(name))
	}
}
