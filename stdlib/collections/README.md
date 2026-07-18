// Standard library: Collections README
# LLPL Collections Module

Comprehensive data structures for the LLPL standard library.

## Table of Contents

- [Linear Collections](#linear-collections)
- [Trees](#trees)
- [Heaps](#heaps)
- [Hash-based Collections](#hash-based-collections)
- [String Collections](#string-collections)
- [Graphs](#graphs)
- [Performance Characteristics](#performance-characteristics)

## Linear Collections

### LinkedList\<T\>

Singly linked list with O(1) insertions at head/tail.

```swift
import "stdlib/collections/collections.llpl"

let list: std::LinkedList<int> = new std::LinkedList<int>()

list.push_front(1)  // [1]
list.push_back(2)   // [1, 2]
list.push_back(3)   // [1, 2, 3]

let first: Result<int, char*> = list.pop_front()  // Returns 1
let size: int = list.size()  // 2

// Access by index
let value: Result<int, char*> = list.get(0)  // Returns 2

// Insert at index
list.insert(1, 5)  // [2, 5, 3]

// Convert to vector
let vec: Vector<int> = list.to_vector()
```

**Methods:**
- `push_front(value)` - Add to beginning
- `push_back(value)` - Add to end
- `pop_front()` - Remove from beginning
- `front()` - Peek at first element
- `back()` - Peek at last element
- `get(index)` - Get element at index
- `insert(index, value)` - Insert at index
- `remove(index)` - Remove at index
- `size()` - Get number of elements
- `is_empty()` - Check if empty
- `clear()` - Remove all elements
- `to_vector()` - Convert to vector

### DoublyLinkedList\<T\>

Doubly linked list with efficient operations at both ends.

```swift
let list: std::DoublyLinkedList<int> = new std::DoublyLinkedList<int>()

list.push_front(1)
list.push_back(2)
list.pop_back()  // O(1) unlike singly linked list

// Iterate backwards
let reversed: Vector<int> = list.reverse_iterate()
```

**Additional Methods:**
- `pop_back()` - Remove from end (O(1))
- `reverse_iterate()` - Get elements in reverse order

### Stack\<T\>

LIFO (Last In, First Out) stack backed by Vector.

```swift
let stack: std::Stack<int> = new std::Stack<int>()

stack.push(1)
stack.push(2)
stack.push(3)

let top: Result<int, char*> = stack.peek()  // Returns 3
let value: Result<int, char*> = stack.pop() // Returns 3

if !stack.is_empty() {
    let next: Result<int, char*> = stack.pop()  // Returns 2
}
```

**Methods:**
- `push(value)` - Add to top
- `pop()` - Remove from top
- `peek()` - Look at top without removing
- `size()` - Number of elements
- `is_empty()` - Check if empty
- `clear()` - Remove all

### Queue\<T\>

FIFO (First In, First Out) queue backed by DoublyLinkedList.

```swift
let queue: std::Queue<int> = new std::Queue<int>()

queue.enqueue(1)
queue.enqueue(2)
queue.enqueue(3)

let first: Result<int, char*> = queue.dequeue()  // Returns 1
let front: Result<int, char*> = queue.front()    // Peek: Returns 2
```

**Methods:**
- `enqueue(value)` - Add to back
- `dequeue()` - Remove from front
- `front()` - Peek at front
- `back()` - Peek at back
- `size()`, `is_empty()`, `clear()`

### Deque\<T\>

Double-ended queue supporting efficient operations at both ends.

```swift
let deque: std::Deque<int> = new std::Deque<int>()

deque.push_front(1)
deque.push_back(2)
deque.push_front(0)  // [0, 1, 2]

deque.pop_front()  // Returns 0
deque.pop_back()   // Returns 2
```

**Methods:**
- `push_front(value)`, `push_back(value)`
- `pop_front()`, `pop_back()`
- `front()`, `back()`
- `size()`, `is_empty()`, `clear()`

### CircularBuffer\<T\>

Fixed-size ring buffer with overwrite capability.

```swift
let buffer: std::CircularBuffer<int> = new std::CircularBuffer<int>(5)

for let i: int = 0, i < 5, i = i + 1 {
    buffer.push(i)  // [0, 1, 2, 3, 4]
}

if buffer.is_full() {
    buffer.push_overwrite(5)  // [1, 2, 3, 4, 5] - overwrites oldest
}

let value: Result<int, char*> = buffer.pop()  // Returns 1
```

**Methods:**
- `push(value)` - Add (fails if full)
- `push_overwrite(value)` - Add (overwrites oldest if full)
- `pop()` - Remove oldest
- `peek()` - Look at oldest
- `is_full()`, `is_empty()`, `size()`, `clear()`

## Trees

### RBTree\<K, V\>

Self-balancing red-black tree with O(log n) operations.

```swift
let tree: std::RBTree<int, String> = new std::RBTree<int, String>()

tree.insert(10, new String("ten"))
tree.insert(5, new String("five"))
tree.insert(15, new String("fifteen"))
tree.insert(3, new String("three"))

// Search
let result: Result<String, char*> = tree.find(10)
if result.is_ok() {
    let value: String = result.unwrap()  // "ten"
}

// Check existence
let exists: bool = tree.contains(5)  // true

// Get min/max
let min: Result<int, char*> = tree.min_key()  // Returns 3
let max: Result<int, char*> = tree.max_key()  // Returns 15

// Get all keys in sorted order
let keys: Vector<int> = tree.keys()  // [3, 5, 10, 15]
let values: Vector<String> = tree.values()

// Tree statistics
let height: int = tree.height()
let size: int = tree.size()
```

**Methods:**
- `insert(key, value)` - Insert key-value pair
- `find(key)` - Find value by key
- `contains(key)` - Check if key exists
- `min_key()`, `max_key()` - Get minimum/maximum key
- `keys()` - Get all keys in sorted order
- `values()` - Get all values in key order
- `size()`, `is_empty()`
- `height()` - Get tree height
- `clear()` - Remove all elements

**Time Complexity:**
- Insert: O(log n)
- Find: O(log n)
- Delete: O(log n) (not yet implemented)
- Min/Max: O(log n)

## Heaps

### BinaryHeap\<T\>

Min-heap implementation with O(log n) insertions.

```swift
let heap: std::BinaryHeap<int> = new std::BinaryHeap<int>()

heap.insert(10)
heap.insert(5)
heap.insert(15)
heap.insert(3)

let min: Result<int, char*> = heap.peek_min()      // Returns 3 (doesn't remove)
let extracted: Result<int, char*> = heap.extract_min()  // Returns 3 (removes)

// Build heap from vector
let values: Vector<int> = new Vector<int>()
values.push(8)
values.push(4)
values.push(12)
heap.heapify(values)  // Efficient O(n) heapification
```

**Methods:**
- `insert(value)` - Add element
- `extract_min()` - Remove and return minimum
- `peek_min()` - Look at minimum
- `heapify(vector)` - Build heap from vector
- `size()`, `is_empty()`, `clear()`

### MaxHeap\<T\>

Max-heap (largest element at top).

```swift
let max_heap: std::MaxHeap<int> = new std::MaxHeap<int>()

max_heap.insert(5)
max_heap.insert(10)
max_heap.insert(3)

let max: Result<int, char*> = max_heap.extract_max()  // Returns 10
```

### PriorityQueue\<T\>

Priority queue with custom priority values (lower = higher priority).

```swift
let pq: std::PriorityQueue<String> = new std::PriorityQueue<String>()

pq.enqueue(new String("Low priority"), 10)
pq.enqueue(new String("High priority"), 1)
pq.enqueue(new String("Medium priority"), 5)

let item: Result<String, char*> = pq.dequeue()  // Returns "High priority"
```

**Methods:**
- `enqueue(value, priority)` - Add with priority
- `dequeue()` - Remove highest priority item
- `peek()` - Look at highest priority
- `size()`, `is_empty()`, `clear()`

## Hash-based Collections

### EnhancedHashMap\<K, V\>

Hash map with automatic resizing and collision handling via chaining.

```swift
let map: std::EnhancedHashMap<String, int> = new std::EnhancedHashMap<String, int>()

map.insert(new String("one"), 1)
map.insert(new String("two"), 2)
map.insert(new String("three"), 3)

// Lookup
let result: Result<int, char*> = map.get(new String("two"))
if result.is_ok() {
    let value: int = result.unwrap()  // 2
}

// Check existence
let exists: bool = map.contains(new String("one"))  // true

// Remove
let removed: Result<int, char*> = map.remove(new String("one"))

// Get all keys and values
let keys: Vector<String> = map.keys()
let values: Vector<int> = map.values()

// Performance metrics
let load_factor: int = map.get_load_factor()  // Percentage
let collisions: int = map.get_collision_count()
```

**Methods:**
- `insert(key, value)` - Insert or update
- `get(key)` - Get value by key
- `contains(key)` - Check existence
- `remove(key)` - Remove key-value pair
- `keys()`, `values()` - Get all keys/values
- `size()`, `is_empty()`, `clear()`
- `get_load_factor()` - Current load percentage
- `get_collision_count()` - Number of collisions

**Features:**
- Automatic resizing at 75% load factor
- Chaining for collision resolution
- O(1) average case operations

### HashSet\<T\>

Set of unique values with set operations.

```swift
let set1: std::HashSet<int> = new std::HashSet<int>()
set1.insert(1)
set1.insert(2)
set1.insert(3)

let set2: std::HashSet<int> = new std::HashSet<int>()
set2.insert(2)
set2.insert(3)
set2.insert(4)

// Set operations
let union_set: std::HashSet<int> = set1.union(set2)        // {1, 2, 3, 4}
let intersection: std::HashSet<int> = set1.intersection(set2)  // {2, 3}
let difference: std::HashSet<int> = set1.difference(set2)      // {1}

// Basic operations
let contains: bool = set1.contains(2)  // true
let removed: bool = set1.remove(1)
let vec: Vector<int> = set1.to_vector()
```

**Methods:**
- `insert(value)` - Add element
- `contains(value)` - Check membership
- `remove(value)` - Remove element
- `union(other)` - Set union
- `intersection(other)` - Set intersection
- `difference(other)` - Set difference
- `to_vector()` - Convert to vector
- `size()`, `is_empty()`, `clear()`

## String Collections

### Trie

Prefix tree for efficient string operations.

```swift
let trie: std::Trie = new std::Trie()

trie.insert("cat")
trie.insert("car")
trie.insert("card")
trie.insert("dog")
trie.insert("dodge")

// Search
let found: bool = trie.search("car")  // true
let not_found: bool = trie.search("ca")  // false (not a complete word)

// Prefix check
let has_prefix: bool = trie.starts_with("ca")  // true

// Get all words with prefix
let words: Vector<String> = trie.get_words_with_prefix("ca")
// Returns: ["car", "card", "cat"]

// Count words with prefix
let count: int = trie.count_prefix("do")  // 2 (dog, dodge)

// Get all words
let all_words: Vector<String> = trie.get_all_words()

// Longest common prefix
let lcp: String = trie.longest_common_prefix()

// Delete word
trie.delete("car")

// Insert with value
trie.insert_with_value("api", 42)
let value_result: Result<int, char*> = trie.search_value("api")
```

**Methods:**
- `insert(word)` - Add word
- `insert_with_value(word, value)` - Add word with associated value
- `search(word)` - Check if word exists
- `search_value(word)` - Get associated value
- `starts_with(prefix)` - Check prefix existence
- `get_words_with_prefix(prefix)` - Get all matching words
- `count_prefix(prefix)` - Count matching words
- `get_all_words()` - Get all words
- `delete(word)` - Remove word
- `longest_common_prefix()` - Find LCP of all words
- `size()`, `is_empty()`

**Use Cases:**
- Autocomplete systems
- Spell checkers
- IP routing tables
- Dictionary implementations

## Graphs

### Graph

Adjacency list representation for sparse graphs.

```swift
let graph: std::Graph = new std::Graph(5, false)  // 5 vertices, undirected

// Add edges
graph.add_edge(0, 1, 10)  // vertex 0 to 1, weight 10
graph.add_edge(1, 2, 5)
graph.add_edge(2, 3, 7)
graph.add_edge(3, 4, 3)
graph.add_edge_unweighted(0, 4)  // weight defaults to 1

// Check edges
let has_edge: bool = graph.has_edge(0, 1)  // true

// Get neighbors
let neighbors: Vector<int> = graph.get_neighbors(1)

// Get edges from vertex
let edges: Vector<Edge> = graph.get_edges(0)

// Degree
let degree: int = graph.get_degree(1)

// Breadth-first search
let bfs_order: Vector<int> = graph.bfs(0)

// Depth-first search
let dfs_order: Vector<int> = graph.dfs(0)

// Connectivity
let connected: bool = graph.is_connected()

// Topological sort (for directed acyclic graphs)
let directed_graph: std::Graph = new std::Graph(4, true)
directed_graph.add_edge_unweighted(0, 1)
directed_graph.add_edge_unweighted(0, 2)
directed_graph.add_edge_unweighted(1, 3)
directed_graph.add_edge_unweighted(2, 3)

let topo_result: Result<Vector<int>, char*> = directed_graph.topological_sort()
// Returns: [0, 1, 2, 3] or [0, 2, 1, 3]

// Cycle detection
let has_cycle: bool = directed_graph.has_cycle_directed()
```

**Methods:**
- `add_edge(from, to, weight)` - Add weighted edge
- `add_edge_unweighted(from, to)` - Add edge with weight 1
- `has_edge(from, to)` - Check edge existence
- `get_neighbors(vertex)` - Get adjacent vertices
- `get_edges(vertex)` - Get all edges from vertex
- `get_degree(vertex)` - Get vertex degree
- `bfs(start)` - Breadth-first search
- `dfs(start)` - Depth-first search
- `is_connected()` - Check if graph is connected
- `topological_sort()` - Topological ordering (DAG only)
- `has_cycle_directed()` - Cycle detection

### GraphMatrix

Adjacency matrix representation for dense graphs.

```swift
let graph: std::GraphMatrix = new std::GraphMatrix(4, false)

graph.add_edge(0, 1, 5)
graph.add_edge(1, 2, 3)
graph.add_edge(2, 3, 1)
graph.add_edge(0, 3, 10)

// Get edge weight
let weight: int = graph.get_weight(0, 1)  // Returns 5

// Floyd-Warshall (all-pairs shortest paths)
let distances: int** = graph.floyd_warshall()
// distances[i][j] contains shortest path from i to j

let shortest_path: int = distances[0][3]  // Shortest path from 0 to 3
```

**Methods:**
- `add_edge(from, to, weight)` - Add edge
- `has_edge(from, to)` - Check edge
- `get_weight(from, to)` - Get edge weight
- `floyd_warshall()` - All-pairs shortest paths

## Performance Characteristics

| Data Structure | Insert | Delete | Search | Space |
|----------------|--------|--------|--------|-------|
| LinkedList | O(1)* | O(n) | O(n) | O(n) |
| DoublyLinkedList | O(1)* | O(1)* | O(n) | O(n) |
| Stack | O(1) | O(1) | - | O(n) |
| Queue | O(1) | O(1) | - | O(n) |
| RBTree | O(log n) | O(log n) | O(log n) | O(n) |
| BinaryHeap | O(log n) | O(log n) | - | O(n) |
| EnhancedHashMap | O(1)† | O(1)† | O(1)† | O(n) |
| HashSet | O(1)† | O(1)† | O(1)† | O(n) |
| Trie | O(m) | O(m) | O(m) | O(ALPHABET_SIZE × n × m) |
| Graph (List) | O(1) | O(degree) | O(degree) | O(V + E) |
| Graph (Matrix) | O(1) | O(1) | O(1) | O(V²) |

*At head/tail
†Average case; O(n) worst case
m = string length, V = vertices, E = edges

## Examples

See `examples/collections/` for complete examples of all data structures.
