#!/bin/bash
# Regenerates the README screenshots in docs/screenshots with GoIDE's --snapshot mode.
# Builds a small demo module in a temp folder (needs network once for its dependency).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/docs/screenshots"
mkdir -p "$OUT"
swift build -c release --product GoIDE >/dev/null
APP="$(swift build -c release --show-bin-path)/GoIDE"

DEMO="$(mktemp -d)/inventory"
mkdir -p "$DEMO"
cd "$DEMO"
go mod init example.com/inventory >/dev/null 2>&1
cat > store.go <<'GO'
package main

import (
	"fmt"
	"sort"
	"strings"

	"github.com/google/uuid"
)

// Item is one product in the store.
type Item struct {
	ID    string
	Name  string
	Price float64
	Stock int
}

// Store keeps items by ID.
type Store struct {
	items map[string]Item
}

func NewStore() *Store {
	return &Store{items: map[string]Item{}}
}

// Add stores an item and returns its new ID.
func (s *Store) Add(name string, price float64, stock int) string {
	id := uuid.NewString()
	s.items[id] = Item{ID: id, Name: name, Price: price, Stock: stock}
	return id
}

// Total is the value of everything in stock.
func (s *Store) Total() float64 {
	total := 0.0
	for _, item := range s.items {
		total += item.Price * float64(item.Stock)
	}
	return total
}

// Report lists items by name.
func (s *Store) Report() string {
	names := make([]string, 0, len(s.items))
	for _, item := range s.items {
		names = append(names, fmt.Sprintf("%-8s %3d × %.2f", item.Name, item.Stock, item.Price))
	}
	sort.Strings(names)
	return strings.Join(names, "\n")
}
GO
cat > main.go <<'GO'
package main

import "fmt"

func main() {
	store := NewStore()
	store.Add("gopher", 12.5, 4)
	store.Add("swift", 9.99, 10)
	total := store.Total()
	fmt.Println(store.Report())
	fmt.Printf("total: %.2f\n", total)
}
GO
cat > store_test.go <<'GO'
package main

import "testing"

func TestTotal(t *testing.T) {
	s := NewStore()
	s.Add("a", 2, 3)
	s.Add("b", 1.5, 2)
	if got := s.Total(); got != 9 {
		t.Errorf("Total() = %v, want 9", got)
	}
}

func TestEmpty(t *testing.T) {
	if got := NewStore().Total(); got != 0 {
		t.Errorf("Total() = %v, want 0", got)
	}
}

func BenchmarkReport(b *testing.B) {
	s := NewStore()
	for i := range 500 {
		s.Add("item", float64(i), i)
	}
	for b.Loop() {
		_ = s.Report()
	}
}
GO
go get github.com/google/uuid@v1.3.0 >/dev/null 2>&1
go mod tidy >/dev/null 2>&1
git init -q && git add -A && git -c user.name=demo -c user.email=demo@example.com commit -qm "demo"
# A change since HEAD, for the gutter bars.
sed -i '' 's|// Total is the value of everything in stock.|// Total is the value of everything in stock (price × stock).|' store.go

shot() { local name="$1"; shift; "$APP" "$DEMO" "$@" --snapshot "$OUT/$name.png"; }
shot editor     "$DEMO/store.go" --snapshot-line 38 --snapshot-type $'\nif item.St' --snapshot-delay 2
shot debugger   "$DEMO/main.go" --snapshot-debug 9 --snapshot-steps 1 --snapshot-delay 3
shot tests      "$DEMO/store.go" --snapshot-tests --snapshot-coverage --snapshot-delay 3
shot dependencies "$DEMO/store.go" --snapshot-modules --snapshot-delay 3
shot profile    "$DEMO/store.go" --snapshot-profile cpu --snapshot-delay 2
shot rename     "$DEMO/store.go" --snapshot-line 36 --snapshot-column 17 --snapshot-rename StockValue --snapshot-delay 3
echo "Screenshots written to $OUT"
