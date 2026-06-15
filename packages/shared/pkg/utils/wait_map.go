package utils

import "sync"

// onceEntry wraps a memoized function so entries can be compared by pointer
// identity when removing them from the map.
type onceEntry struct {
	fn func() error
}

// WaitMap allows you to wait for functions with given keys and execute them only once.
// If a function fails, its entry is removed so a subsequent Wait re-executes it
// (failures are not cached permanently).
type WaitMap struct {
	mu sync.Mutex
	m  map[int64]*onceEntry
}

func NewWaitMap() *WaitMap {
	return &WaitMap{
		m: make(map[int64]*onceEntry),
	}
}

// Wait waits for the function with the given key to be executed.
// If the function is already executing, it waits for it to finish.
// If the function is not yet executing, it executes the function and returns its result.
// On failure the entry is evicted so the next Wait for the same key retries.
func (m *WaitMap) Wait(key int64, fn func() error) error {
	m.mu.Lock()

	entry, ok := m.m[key]
	if !ok {
		entry = &onceEntry{fn: sync.OnceValue(fn)}
		m.m[key] = entry
	}

	m.mu.Unlock()

	err := entry.fn()
	if err != nil {
		// Don't cache failures: remove the entry so a later Wait re-executes fn.
		// Compare by pointer to avoid deleting an entry inserted by a newer caller.
		m.mu.Lock()
		if cur, ok := m.m[key]; ok && cur == entry {
			delete(m.m, key)
		}
		m.mu.Unlock()
	}

	return err
}
