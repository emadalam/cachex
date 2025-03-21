defmodule Cachex do
  @moduledoc """
  Cachex provides a straightforward interface for in-memory key/value storage.

  Cachex is an extremely fast, designed for caching but also allowing for more
  general in-memory storage. The main goal of Cachex is achieve a caching
  implementation with a wide array of options, without sacrificing performance.
  Internally, Cachex is backed by ETS, allowing for an easy-to-use interface
  sitting upon extremely well tested tools.

  Cachex comes with support for all of the following (amongst other things):

  - Time-based key expirations
  - Maximum size protection
  - Pre/post execution hooks
  - Proactive/reactive cache warming
  - Transactions and row locking
  - Asynchronous write operations
  - Distribution across app nodes
  - Syncing to a local filesystem
  - Idiomatic cache streaming
  - Batched write operations
  - User command invocation
  - Statistics gathering

  All features are optional to allow you to tune based on the throughput needed.

  Please see `Cachex.start_link/2` inside the Cachex [documentation](https://hexdocs.pm/cachex)
  for further details about how to configure these  options and example usage.
  """
  use Supervisor

  # add all imports
  import Cachex.Error
  import Cachex.Spec

  # allow unsafe generation
  use Unsafe.Generator,
    handler: :unwrap_unsafe

  # add some aliases
  alias Cachex.Options
  alias Cachex.Query, as: Q
  alias Cachex.Router
  alias Cachex.Services

  # alias any services
  alias Services.Overseer

  # import util macros
  require Router
  require Overseer

  # avoid inspect clashes
  import Kernel, except: [inspect: 2]

  # the type aliases for a cache type
  @type t :: atom | Cachex.Spec.cache()

  # custom status type
  @type status :: :ok | :error

  # generate unsafe definitions
  @unsafe [
    clear: [1, 2],
    decr: [2, 3, 4],
    del: [2, 3],
    empty?: [1, 2],
    execute: [2, 3],
    exists?: [2, 3],
    expire: [3, 4],
    expire_at: [3, 4],
    export: [1, 2],
    fetch: [3, 4],
    get: [2, 3],
    get_and_update: [3, 4],
    import: [2, 3],
    incr: [2, 3, 4],
    inspect: [2, 3],
    invoke: [3, 4],
    keys: [1, 2],
    persist: [2, 3],
    prune: [2, 3],
    purge: [1, 2],
    put: [3, 4],
    put_many: [2, 3],
    refresh: [2, 3],
    reset: [1, 2],
    restore: [2, 3],
    save: [2, 3],
    size: [1, 2],
    stats: [1, 2],
    stream: [1, 2, 3],
    take: [2, 3],
    touch: [2, 3],
    transaction: [3, 4],
    ttl: [2, 3],
    update: [3, 4],
    warm: [1, 2]
  ]

  ##############
  # Public API #
  ##############

  @doc """
  Creates a new Cachex cache service tree, linked to the current process.

  This will link the cache to the current process, so if your process dies the
  cache will also die. If you don't want this behaviour, please use `start/2`.

  The first argument should be a unique atom, used as the name of the cache
  service for future calls through to Cachex. For all options requiring a record
  argument, please import `Cachex.Spec` in advance.

  ## Options

    * `:commands`

      This option allows you to attach a set of custom commands to a cache in
      order to provide shorthand execution. A cache command must be constructed
      using the `:command` record provided by `Cachex.Spec`.

      A cache command will adhere to these basic rules:

      - If you define a `:read` command, the return value of your command will
        be passed through as the result of your call to `invoke/4`.
      - If you define a `:write` command, your command must return a two-element
        Tuple. The first element represents the value being returned from your
        `invoke/4` call, and the second represents the value to write back into
        the cache (as an update). If your command does not fit this, errors will
        happen (intentionally).

      Commands are set on a per-cache basis, but can be reused across caches. They're
      set only on cache startup and cannot be modified after the cache tree is created.

          iex> import Cachex.Spec
          ...>
          ...> Cachex.start_link(:my_cache, [
          ...>   commands: [
          ...>     last: command(type:  :read, execute:   &List.last/1),
          ...>     trim: command(type: :write, execute: &String.trim/1)
          ...>   ]
          ...> ])
          { :ok, _pid }

      Either a `Keyword` or a `Map` can be provided against the `:commands` option as
      we only use `Enum` to verify them before attaching them internally. Please see
      the `Cachex.Spec.command/1` documentation for further customization options.

    * `:compressed`

      This option will specify whether this cache should have enable ETS compression,
      which is likely to reduce memory overhead. Please note that there is a potential
      for this option to slow your cache due to compression overhead, so benchmark as
      appropriate when using this option. This option defaults to `false`.

          iex> Cachex.start_link(:my_cache, [ compressed: true ])
          { :ok, _pid }

    * `:expiration`

      The expiration option provides the ability to customize record expiration at
      a global cache level. The value provided here must be a valid `:expiration`
      record provided by `Cachex.Spec`.

          iex> import Cachex.Spec
          ...>
          ...> Cachex.start_link(:my_cache, [
          ...>   expiration: expiration(
          ...>     # how often cleanup should occur
          ...>     interval: :timer.seconds(30),
          ...>
          ...>     # default record expiration
          ...>     default: :timer.seconds(60),
          ...>
          ...>     # whether to enable lazy checking
          ...>     lazy: true
          ...>   )
          ...> ])
          { :ok, _pid }

      Please see the `Cachex.Spec.expiration/1` documentation for further customization
      options.

    * `:hooks`

      The `:hooks` option allow the user to attach a list of notification hooks to
      enable listening on cache actions (either before or after they happen). These
      hooks should be valid `:hook` records provided by `Cachex.Spec`. Example hook
      implementations can be found in `Cachex.Stats` and `Cachex.Policy.LRW`.

          iex> import Cachex.Spec
          ...>
          ...> Cachex.start_link(:my_cache, [
          ...>   hooks: [
          ...>     hook(module: MyHook, name: :my_hook, args: { })
          ...>   ]
          ...> ])
          { :ok, _pid }

      Please see the `Cachex.Spec.hook/1` documentation for further customization options.

    * `:ordered`

      This option will specify whether this cache should enable ETS ordering, which can
      improve performance if ordered traversal of a cache is required. Setting `:ordered`
      to `true` will result in both insert and lookup times being proportional to the
      logarithm of the number of objects in the table. This option defaults to `false`.

          iex> Cachex.start_link(:my_cache, [ ordered: true ])
          { :ok, _pid }

    * `:router`

      This option determines which module is used for cache routing inside distributed
      caches. You can provide either a full `record` structure or simply a module name.

          iex> import Cachex.Spec
          ...>
          ...> Cachex.start_link(:my_cache, [
          ...>   router: router(
          ...>     module: Cachex.Router.Jump,
          ...>     options: []
          ...>   )
          ...> ])
          { :ok, _pid }

      Please see the `Cachex.Spec.router/1` documentation for further customization options.

    * `:transactions`

      This option will specify whether this cache should have transactions and row
      locking enabled from cache startup. Please note that even if this is false,
      it will be enabled the moment a transaction is executed. It's recommended to
      leave this as default as it will handle most use cases in the most performant
      way possible.

          iex> Cachex.start_link(:my_cache, [ transactions: true ])
          { :ok, _pid }

    * `:warmers`

      The `:warmers` option allows the user to attach a list of warming modules to
      a cache. These cache warmers must implement the `Cachex.Warmer` behaviour
      and are defined as `warmer` records.

      The only required value is the `:module` definition, although you can also
      choose to provide a name and state to attach to the warmer process. The flag
      `:required` is used to control whether the warmer must finish execution before
      the cache supervision tree can be considered fully started.

          iex> import Cachex.Spec
          ...>
          ...> Cachex.start_link(:my_cache, [
          ...>   warmers: [
          ...>     warmer(
          ...>       required: true,
          ...>       module: MyProject.DatabaseWarmer,
          ...>       state: connection,
          ...>       name: MyProject.DatabaseWarmer
          ...>     )
          ...>   ]
          ...> ])
          { :ok, _pid }

      Please see the `Cachex.Spec.warmer/1` documentation for further customization options.

  """
  @spec start_link(atom, Keyword.t()) :: {atom, pid}
  def start_link(name, options) when is_atom(name) and is_list(options) do
    with {:ok, true} <- ensure_started(),
         {:ok, true} <- ensure_unused(name),
         {:ok, cache} <- Options.parse(name, options),
         {:ok, pid} = Supervisor.start_link(__MODULE__, cache, name: name),
         {:ok, cache} = Services.link(cache),
         {:ok, cache} <- setup_router(cache),
         ^cache <- Overseer.update(name, cache),
         :ok <- setup_warmers(cache) do
      {:ok, pid}
    end
  end

  @doc false
  # Grace handlers for `Supervisor.child_spec/1`.
  #
  # Without this, Cachex is not compatible per Elixir's documentation.
  @spec start_link(atom | Keyword.t()) :: {atom, pid} | {:error, :invalid_name}
  def start_link([name]) when is_atom(name),
    do: start_link(name)

  def start_link([name, options]) when is_atom(name) and is_list(options),
    do: start_link(name, options)

  def start_link(options) when is_list(options) do
    case Keyword.fetch(options, :name) do
      {:ok, name} ->
        start_link(name, options)

      _invalid ->
        error(:invalid_name)
    end
  end

  def start_link(name) when is_atom(name),
    do: start_link(name, [])

  @doc """
  Creates a new Cachex cache service tree.

  This will not link the cache to the current process, so if your process dies
  the cache will continue to live. If you don't want this behaviour, please use
  the provided `Cachex.start_link/2`.

  This function is otherwise identical to `start_link/2` so please see that
  documentation for further information and configuration.
  """
  @spec start(atom, Keyword.t()) :: {atom, pid}
  def start(name, options \\ []) do
    with {:ok, pid} <- start_link(name, options), true <- :erlang.unlink(pid) do
      {:ok, pid}
    end
  end

  @doc false
  # Basic initialization phase for a cache.
  #
  # This will start all cache services required using the `Cachex.Services`
  # module and attach them under a Supervisor instance backing the cache.
  @spec init(cache :: Cachex.t()) ::
          {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(cache() = cache) do
    cache
    |> Services.cache_spec()
    |> Supervisor.init(strategy: :one_for_one)
  end

  @doc """
  Removes all entries from a cache.

  The returned numeric value will contain the total number of keys removed
  from the cache. This is equivalent to running `size/2` before running
  the internal clear operation.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.get(:my_cache, "key")
      iex> Cachex.size(:my_cache)
      { :ok, 1 }

      iex> Cachex.clear(:my_cache)
      { :ok, 1 }

      iex> Cachex.size(:my_cache)
      { :ok, 0 }

  """
  @spec clear(Cachex.t(), Keyword.t()) :: {status, integer}
  def clear(cache, options \\ []) when is_list(options),
    do: Router.route(cache, {:clear, [options]})

  @doc """
  Decrements an entry in the cache.

  This will overwrite any value that was previously set against the provided key.

  ## Options

    * `:default`

      An initial value to set the key to if it does not exist. This will
      take place *before* the decrement call. Defaults to 0.

  ## Examples

      iex> Cachex.put(:my_cache, "my_key", 10)
      iex> Cachex.decr(:my_cache, "my_key")
      { :ok, 9 }

      iex> Cachex.put(:my_cache, "my_new_key", 10)
      iex> Cachex.decr(:my_cache, "my_new_key", 5)
      { :ok, 5 }

      iex> Cachex.decr(:my_cache, "missing_key", 5, default: 2)
      { :ok, -3 }

  """
  @spec decr(Cachex.t(), any, integer, Keyword.t()) :: {status, integer}
  def decr(cache, key, amount \\ 1, options \\ [])
      when is_integer(amount) and is_list(options) do
    via_opt = via({:decr, [key, amount, options]}, options)
    incr(cache, key, amount * -1, via_opt)
  end

  @doc """
  Removes an entry from a cache.

  This will return `{ :ok, true }` regardless of whether a key has been removed
  or not. The `true` value can be thought of as "is key no longer present?".

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.get(:my_cache, "key")
      { :ok, "value" }

      iex> Cachex.del(:my_cache, "key")
      { :ok, true }

      iex> Cachex.get(:my_cache, "key")
      { :ok, nil }

  """
  @spec del(Cachex.t(), any, Keyword.t()) :: {status, boolean}
  def del(cache, key, options \\ []) when is_list(options),
    do: Router.route(cache, {:del, [key, options]})

  @doc """
  Determines whether a cache contains any entries.

  This does not take the expiration time of keys into account. As such,
  if there are any unremoved (but expired) entries in the cache, they
  will be included in the returned determination.

  ## Examples

      iex> Cachex.put(:my_cache, "key1", "value1")
      iex> Cachex.empty?(:my_cache)
      { :ok, false }

      iex> Cachex.clear(:my_cache)
      iex> Cachex.empty?(:my_cache)
      { :ok, true }

  """
  @spec empty?(Cachex.t(), Keyword.t()) :: {status, boolean}
  def empty?(cache, options \\ []) when is_list(options),
    do: Router.route(cache, {:empty?, [options]})

  @doc """
  Executes multiple functions in the context of a cache.

  This can be used when carrying out several cache operations at once
  to avoid the overhead of cache loading and jumps between processes.

  This does not provide a transactional execution, it simply avoids
  the overhead involved in the initial calls to a cache. For a transactional
  implementation, please see `transaction/3`.

  To take advantage of the cache context, ensure to use the cache
  instance provided when executing cache calls. If this is not done
  you will see zero benefits from using `execute/3`.

  ## Examples

      iex> Cachex.put(:my_cache, "key1", "value1")
      iex> Cachex.put(:my_cache, "key2", "value2")
      iex> Cachex.execute(:my_cache, fn(worker) ->
      ...>   val1 = Cachex.get!(worker, "key1")
      ...>   val2 = Cachex.get!(worker, "key2")
      ...>   [val1, val2]
      ...> end)
      { :ok, [ "value1", "value2" ] }

  """
  @spec execute(Cachex.t(), function, Keyword.t()) :: {status, any}
  def execute(cache, operation, options \\ [])
      when is_function(operation, 1) and is_list(options) do
    Overseer.with(cache, fn cache ->
      {:ok, operation.(cache)}
    end)
  end

  @doc """
  Determines whether an entry exists in a cache.

  This will take expiration times into account, meaning that
  expired entries will not be considered to exist.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.exists?(:my_cache, "key")
      { :ok, true }

      iex> Cachex.exists?(:my_cache, "missing_key")
      { :ok, false }

  """
  @spec exists?(Cachex.t(), any, Keyword.t()) :: {status, boolean}
  def exists?(cache, key, options \\ []) when is_list(options),
    do: Router.route(cache, {:exists?, [key, options]})

  @doc """
  Places an expiration time on an entry in a cache.

  The provided expiration must be a integer value representing the
  lifetime of the entry in milliseconds. If the provided value is
  not positive, the entry will be immediately evicted.

  If the entry does not exist, no changes will be made in the cache.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.expire(:my_cache, "key", :timer.seconds(5))
      { :ok, true }

      iex> Cachex.expire(:my_cache, "missing_key", :timer.seconds(5))
      { :ok, false }

  """
  @spec expire(Cachex.t(), any, number | nil, Keyword.t()) :: {status, boolean}
  def expire(cache, key, expiration, options \\ [])
      when (is_nil(expiration) or is_number(expiration)) and is_list(options),
      do: Router.route(cache, {:expire, [key, expiration, options]})

  @doc """
  Updates an entry in a cache to expire at a given time.

  Unlike `expire/4` this call uses an instant in time, rather than a
  duration. The same semantics apply as calls to `expire/4` in that
  instants which have passed will result in immediate eviction.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.expire_at(:my_cache, "key", 1455728085502)
      { :ok, true }

      iex> Cachex.expire_at(:my_cache, "missing_key", 1455728085502)
      { :ok, false }

  """
  @spec expire_at(Cachex.t(), any, number, Keyword.t()) :: {status, boolean}
  def expire_at(cache, key, timestamp, options \\ [])
      when is_number(timestamp) and is_list(options) do
    via_opts = via({:expire_at, [key, timestamp, options]}, options)
    expire(cache, key, timestamp - now(), via_opts)
  end

  @doc """
  Exports all entries from a cache.

  This provides a raw read of the entire backing table into a list
  of cache records for export purposes.

  This function is very heavy, so it should typically only be used
  when debugging and/or exporting of tables (although the latter case
  should really use `Cachex.save/3`).

   ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.export(:my_cache)
      { :ok, [ { :entry, "key", 1538714590095, nil, "value" } ] }

  """
  @spec export(Cachex.t(), Keyword.t()) :: {status, [Cachex.Spec.entry()]}
  def export(cache, options \\ []) when is_list(options),
    do: Router.route(cache, {:export, [options]})

  @doc """
  Fetches an entry from a cache, generating a value on cache miss.

  If the entry requested is found in the cache, this function will
  operate in the same way as `get/3`. If the entry is not contained
  in the cache, the provided fallback function will be executed.

  A fallback function is a function used to lazily generate a value
  to place inside a cache on miss. Consider it a way to achieve the
  ability to create a read-through cache.

  A fallback function should return a Tuple consisting of a `:commit`
  or `:ignore` tag and a value. If the Tuple is tagged `:commit` the
  value will be placed into the cache and then returned. If tagged
  `:ignore` the value will be returned without being written to the
  cache. If you return a value which does not fit this structure, it
  will be assumed that you are committing the value.

  As of Cachex v3.6, you can also provide a third element in a `:commit`
  Tuple, to allow passthrough of options from within your fallback. The
  options supported in this list match the options you can provide to a
  call of `Cachex.put/4`. An example is the `:expire` option to set an
  expiration from directly inside your fallback.

  If a fallback function has an arity of 1, the requested entry key
  will be passed through to allow for contextual computation. If a
  function has an arity of 0, it will be executed without arguments.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.fetch(:my_cache, "key", fn(key) ->
      ...>   { :commit, String.reverse(key) }
      ...> end)
      { :ok, "value" }

      iex> Cachex.fetch(:my_cache, "missing_key", fn(key) ->
      ...>   { :ignore, String.reverse(key) }
      ...> end)
      { :ignore, "yek_gnissim" }

      iex> Cachex.fetch(:my_cache, "missing_key", fn(key) ->
      ...>   { :commit, String.reverse(key) }
      ...> end)
      { :commit, "yek_gnissim" }

      iex> Cachex.fetch(:my_cache, "missing_key_expires", fn(key) ->
      ...>   { :commit, String.reverse(key), expire: :timer.seconds(60) }
      ...> end)
      { :commit, "seripxe_yek_gnissim" }

  """
  @spec fetch(Cachex.t(), any, function(), Keyword.t()) ::
          {status | :commit | :ignore, any}
  def fetch(cache, key, fallback, options \\ [])
      when is_function(fallback) and is_list(options),
      do: Router.route(cache, {:fetch, [key, fallback, options]})

  @doc """
  Retrieves an entry from a cache.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.get(:my_cache, "key")
      { :ok, "value" }

      iex> Cachex.get(:my_cache, "missing_key")
      { :ok, nil }

  """
  @spec get(Cachex.t(), any, Keyword.t()) :: {atom, any}
  def get(cache, key, options \\ []) when is_list(options),
    do: Router.route(cache, {:get, [key, options]})

  @doc """
  Retrieves and updates an entry in a cache.

  This operation can be seen as an internal mutation, meaning that any previously
  set expiration time is kept as-is.

  This function accepts the same return syntax as fallback functions, in that if
  you return a Tuple of the form `{ :ignore, value }`, the value is returned from
  the call but is not written to the cache. You can use this to abandon writes
  which began eagerly (for example if a key is actually missing)

  See the `fetch/4` documentation for more information on return formats.

  ## Examples

      iex> Cachex.put(:my_cache, "key", [2])
      iex> Cachex.get_and_update(:my_cache, "key", &([1|&1]))
      { :commit, [1, 2] }

      iex> Cachex.get_and_update(:my_cache, "missing_key", fn
      ...>   (nil) -> { :ignore, nil }
      ...>   (val) -> { :commit, [ "value" | val ] }
      ...> end)
      { :ignore, nil }

  """
  @spec get_and_update(Cachex.t(), any, function, Keyword.t()) ::
          {:commit | :ignore, any}
  def get_and_update(cache, key, updater, options \\ [])
      when is_function(updater, 1) and is_list(options),
      do: Router.route(cache, {:get_and_update, [key, updater, options]})

  @doc """
  Retrieves a list of all entry keys from a cache.

  The order these keys are returned should be regarded as unordered.

  ## Examples

      iex> Cachex.put(:my_cache, "key1", "value1")
      iex> Cachex.put(:my_cache, "key2", "value2")
      iex> Cachex.put(:my_cache, "key3", "value3")
      iex> Cachex.keys(:my_cache)
      { :ok, [ "key2", "key1", "key3" ] }

      iex> Cachex.clear(:my_cache)
      iex> Cachex.keys(:my_cache)
      { :ok, [] }

  """
  @spec keys(Cachex.t(), Keyword.t()) :: {status, [any]}
  def keys(cache, options \\ []) when is_list(options),
    do: Router.route(cache, {:keys, [options]})

  @doc """
  Imports an export set into a cache.

  This provides a raw import of a previously exported cache via the use
  of the `export/2` command.

   ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.import(:my_cache, [ { :entry, "key", "value", 1538714590095, nil } ])
      { :ok, 1 }

  """
  @spec import(Cachex.t(), Enumerable.t(), Keyword.t()) :: {status, integer}
  def import(cache, entries, options \\ []) when is_list(options),
    do: Router.route(cache, {:import, [entries, options]})

  @doc """
  Increments an entry in the cache.

  This will overwrite any value that was previously set against the provided key.

  ## Options

    * `:default`

      An initial value to set the key to if it does not exist. This will
      take place *before* the increment call. Defaults to 0.

  ## Examples

      iex> Cachex.put(:my_cache, "my_key", 10)
      iex> Cachex.incr(:my_cache, "my_key")
      { :ok, 11 }

      iex> Cachex.put(:my_cache, "my_new_key", 10)
      iex> Cachex.incr(:my_cache, "my_new_key", 5)
      { :ok, 15 }

      iex> Cachex.incr(:my_cache, "missing_key", 5, default: 2)
      { :ok, 7 }

  """
  @spec incr(Cachex.t(), any, integer, Keyword.t()) :: {status, integer}
  def incr(cache, key, amount \\ 1, options \\ [])
      when is_integer(amount) and is_list(options),
      do: Router.route(cache, {:incr, [key, amount, options]})

  @doc """
  Inspects various aspects of a cache.

  These operations should be regarded as debug tools, and should really
  only happen outside of production code (unless absolutely) necessary.

  Accepted options are only provided for convenience and should not be
  heavily relied upon.  They are not part of the public interface
  (despite being documented) and as such  may be removed at any time
  (however this does not mean that they will be).

  Please use cautiously. `inspect/2` is provided mainly for testing
  purposes and so performance isn't as much of a concern. It should
  also be noted that `inspect/2` will *always* operate locally.

  ## Options

    * `:cache`

      Retrieves the internal cache record for a cache.

    * `{ :entry, key }`

      Retrieves a raw entry record from inside a cache.

    * `{ :expired, :count }`

      Retrieves the number of expired entries which currently live in the cache
      but have not yet been removed by cleanup tasks (either scheduled or lazy).

    * `{ :expired, :keys }`

      Retrieves the list of expired entry keys which current live in the cache
      but have not yet been removed by cleanup tasks (either scheduled or lazy).

    * `{ :janitor, :last }`

      Retrieves metadata about the last execution of the Janitor service for
      the specified cache.

    * `{ :memory, :bytes }`

      Retrieves an approximate memory footprint of a cache in bytes.

    * `{ :memory, :binary }`

      Retrieves an approximate memory footprint of a cache in binary format.

    * `{ :memory, :words }`

      Retrieve an approximate memory footprint of a cache as a number of
      machine words.

  ## Examples

      iex> Cachex.inspect(:my_cache, :cache)
      {:ok,
        {:cache, :my_cache, %{}, {:expiration, nil, 3000, true}, {:fallback, nil, nil},
          {:hooks, [], []}, {:limit, nil, Cachex.Policy.LRW, 0.1, []}, false, []}}

      iex> Cachex.inspect(:my_cache, { :entry, "my_key" } )
      { :ok, { :entry, "my_key", 1475476615662, 1, "my_value" } }

      iex> Cachex.inspect(:my_cache, { :expired, :count })
      { :ok, 0 }

      iex> Cachex.inspect(:my_cache, { :expired, :keys })
      { :ok, [ ] }

      iex> Cachex.inspect(:my_cache, { :janitor, :last })
      { :ok, %{ count: 0, duration: 57, started: 1475476530925 } }

      iex> Cachex.inspect(:my_cache, { :memory, :binary })
      { :ok, "10.38 KiB" }

      iex> Cachex.inspect(:my_cache, { :memory, :bytes })
      { :ok, 10624 }

      iex> Cachex.inspect(:my_cache, { :memory, :words })
      { :ok, 1328 }

  """
  @spec inspect(Cachex.t(), atom | tuple, Keyword.t()) :: {status, any}
  def inspect(cache, option, options \\ []) when is_list(options),
    do: Router.route(cache, {:inspect, [option, options]})

  @doc """
  Invokes a custom command against a cache entry.

  The provided command name must be a valid command which was
  previously attached to the cache in calls to `start_link/2`.

  ## Examples

      iex> import Cachex.Spec
      iex>
      iex> Cachex.start_link(:my_cache, [
      ...>    commands: [
      ...>      last: command(type: :read, execute: &List.last/1)
      ...>    ]
      ...> ])
      { :ok, _pid }

      iex> Cachex.put(:my_cache, "my_list", [ 1, 2, 3 ])
      iex> Cachex.invoke(:my_cache, :last, "my_list")
      { :ok, 3 }

  """
  @spec invoke(Cachex.t(), atom, any, Keyword.t()) :: any
  def invoke(cache, cmd, key, options \\ []) when is_list(options),
    do: Router.route(cache, {:invoke, [cmd, key, options]})

  @doc """
  Removes an expiration time from an entry in a cache.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value", expiration: 1000)
      iex> Cachex.persist(:my_cache, "key")
      { :ok, true }

      iex> Cachex.persist(:my_cache, "missing_key")
      { :ok, false }

  """
  @spec persist(Cachex.t(), any, Keyword.t()) :: {status, boolean}
  def persist(cache, key, options \\ []) when is_list(options),
    do: expire(cache, key, nil, via({:persist, [key, options]}, options))

  @doc """
  Prunes to a maximum size of records in a cache.

  Pruning is done via a Least Recently Written (LRW) approach, determined by the
  modification time inside each cache record to avoid storing additional state.

  For full details on this feature, please see the section of the documentation
  related to limitation of caches.

  ## Options

    * `:buffer`

      Allows customization of the internal batching when paginating the cursor
      coming back from ETS. It's unlikely this will ever need changing.

    * `:reclaim`

      Provides control over thrashing by evicting an additonal number of cache
      entries beyond the maximum size. This option accepts a percentage (as a
      decimal) of extra keys to evict, to provide buffer between pruning passes.
      Defaults to `0.1` (i.e. 10%).

  ## Examples

      iex> Cachex.put(:my_cache, "key1", "value1")
      { :ok, true }

      iex> :timer.sleep(1)
      :ok

      iex> Cachex.put(:my_cache, "key2", "value2")
      { :ok, true }

      iex> Cachex.prune(:my_cache, 1, reclaim: 0)
      { :ok, true }

      iex> Cachex.keys(:my_cache)
      { :ok, [ "key2"] }

  """
  @spec prune(Cachex.t(), integer, Keyword.t()) :: {status, boolean}
  def prune(cache, size, options \\ [])
      when is_positive_integer(size) and is_list(options),
      do: Router.route(cache, {:prune, [size, options]})

  @doc """
  Triggers a cleanup of all expired entries in a cache.

  This can be used to implement custom eviction policies rather than
  relying on the internal Janitor service. Take care when using this
  method though; calling `purge/2` manually will result in a purge
  firing inside the calling process.

  ## Examples

      iex> Cachex.purge(:my_cache)
      { :ok, 15 }

  """
  @spec purge(Cachex.t(), Keyword.t()) :: {status, number}
  def purge(cache, options \\ []) when is_list(options),
    do: Router.route(cache, {:purge, [options]})

  @doc """
  Places an entry in a cache.

  This will overwrite any value that was previously set against the provided key,
  and overwrite any TTLs which were already set.

  ## Options

    * `:expire`

      An expiration value to set for the provided key (time-to-live), overriding
      any default expirations set on a cache. This value should be in milliseconds.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      { :ok, true }

      iex> Cachex.put(:my_cache, "key", "value", expire: :timer.seconds(5))
      iex> Cachex.ttl(:my_cache, "key")
      { :ok, 5000 }

  """
  @spec put(Cachex.t(), any, any, Keyword.t()) :: {status, boolean}
  def put(cache, key, value, options \\ []) when is_list(options),
    do: Router.route(cache, {:put, [key, value, options]})

  @doc """
  Places a batch of entries in a cache.

  This operates in the same way as `put/4`, except that multiple keys can be
  inserted in a single atomic batch. This is a performance gain over writing
  keys using multiple calls to `put/4`, however it's a performance penalty
  when writing a single key pair due to some batching overhead.

  ## Options

    * `:expire`

      An expiration value to set for the provided keys (time-to-live), overriding
      any default expirations set on a cache. This value should be in milliseconds.

  ## Examples

      iex> Cachex.put_many(:my_cache, [ { "key", "value" } ])
      { :ok, true }

      iex> Cachex.put_many(:my_cache, [ { "key", "value" } ], expire: :timer.seconds(5))
      iex> Cachex.ttl(:my_cache, "key")
      { :ok, 5000 }

  """
  @spec put_many(Cachex.t(), [{any, any}], Keyword.t()) :: {status, boolean}
  def put_many(cache, pairs, options \\ [])
      when is_list(pairs) and is_list(options),
      do: Router.route(cache, {:put_many, [pairs, options]})

  @doc """
  Refreshes an expiration for an entry in a cache.

  Refreshing an expiration will reset the existing expiration with an offset
  from the current time - i.e. if you set an expiration of 5 minutes and wait
  3 minutes before refreshing, the entry will expire 8 minutes after the initial
  insertion.

  ## Examples

      iex> Cachex.put(:my_cache, "my_key", "my_value", expire: :timer.seconds(5))
      iex> Process.sleep(4)
      iex> Cachex.ttl(:my_cache, "my_key")
      { :ok, 1000 }

      iex> Cachex.refresh(:my_cache, "my_key")
      iex> Cachex.ttl(:my_cache, "my_key")
      { :ok, 5000 }

      iex> Cachex.refresh(:my_cache, "missing_key")
      { :ok, false }

  """
  @spec refresh(Cachex.t(), any, Keyword.t()) :: {status, boolean}
  def refresh(cache, key, options \\ []) when is_list(options),
    do: Router.route(cache, {:refresh, [key, options]})

  @doc """
  Resets a cache by clearing the keyspace and restarting any hooks.

  ## Options

    * `:hooks`

      A whitelist of hooks to reset on the cache instance (call the
      initialization phase of a hook again). This will default to
      resetting all hooks associated with a cache, which is usually
      the desired behaviour.

    * `:only`

      A whitelist of components to reset, which can currently contain
      either the `:cache` or `:hooks` tag to determine what to reset.
      This will default to `[ :cache, :hooks ]`.

  ## Examples

      iex> Cachex.put(:my_cache, "my_key", "my_value")
      iex> Cachex.reset(:my_cache)
      iex> Cachex.size(:my_cache)
      { :ok, 0 }

      iex> Cachex.reset(:my_cache, [ only: :hooks ])
      { :ok, true }

      iex> Cachex.reset(:my_cache, [ only: :hooks, hooks: [ MyHook ] ])
      { :ok, true }

      iex> Cachex.reset(:my_cache, [ only: :cache ])
      { :ok, true }

  """
  @spec reset(Cachex.t(), Keyword.t()) :: {status, true}
  def reset(cache, options \\ []) when is_list(options),
    do: Router.route(cache, {:reset, [options]})

  @doc """
  Deserializes a cache from a location on a filesystem.

  This operation will read the current state of a cache from a provided
  location on a filesystem. This function will only understand files
  which have previously been created using `Cachex.save/3`.

  It is the responsibility of the user to ensure that the location is
  able to be read from, not the responsibility of Cachex.

  ## Options

    * `:trust`

      Allow for loading from trusted or untrusted sources; trusted
      sources can load atoms into the table, whereas untrusted sources
      cannot. Defaults to `true`.

  ## Examples

      iex> Cachex.put(:my_cache, "my_key", 10)
      iex> Cachex.save(:my_cache, "/tmp/my_backup")
      { :ok, true }

      iex> Cachex.size(:my_cache)
      { :ok, 1 }

      iex> Cachex.clear(:my_cache)
      iex> Cachex.size(:my_cache)
      { :ok, 0 }

      iex> Cachex.restore(:my_cache, "/tmp/my_backup")
      { :ok, 1 }

      iex> Cachex.size(:my_cache)
      { :ok, 1 }

  """
  @spec restore(Cachex.t(), binary, Keyword.t()) :: {status, integer}
  def restore(cache, path, options \\ [])
      when is_binary(path) and is_list(options),
      do: Router.route(cache, {:restore, [path, options]})

  @doc """
  Serializes a cache to a location on a filesystem.

  This operation will write the current state of a cache to a provided
  location on a filesystem. The written state can be used alongside the
  `Cachex.restore/3` command to import back in the future.

  It is the responsibility of the user to ensure that the location is
  able to be written to, not the responsibility of Cachex.

  ## Options

    * `:buffer`

      Allows customization of the internal batching when paginating the cursor
      coming back from ETS. It's unlikely this will ever need changing.

  ## Examples

      iex> Cachex.save(:my_cache, "/tmp/my_default_backup")
      { :ok, true }

  """
  @spec save(Cachex.t(), binary, Keyword.t()) :: {status, any}
  def save(cache, path, options \\ [])
      when is_binary(path) and is_list(options),
      do: Router.route(cache, {:save, [path, options]})

  @doc """
  Retrieves the total size of a cache.

  By default this does not take expiration time of entries inside the
  cache into account, making it an `O(1)` call. This behaviour can be
  modified by passing `expired: false` to account for expirations, but
  please note that this is a much more involved calculation.

  ## Options

    * `:expired`

      Whether or not to include expired records in the returned total. This
      is a boolean value which defaults to `true`.

  ## Examples

      iex> Cachex.put(:my_cache, "key1", "value1")
      iex> Cachex.put(:my_cache, "key2", "value2")
      iex> Cachex.put(:my_cache, "key3", "value3", expire: 1)
      iex> Cachex.size(:my_cache)
      { :ok, 3 }

      iex> Cachex.size(:my_cache, expired: false)
      { :ok, 2 }

  """
  @spec size(Cachex.t(), Keyword.t()) :: {status, number}
  def size(cache, options \\ []) when is_list(options),
    do: Router.route(cache, {:size, [options]})

  @doc """
  Retrieves statistics about a cache.

  This will only provide statistics if the `:hooks` option with `hook(module: Cachex.Stats)` was
  provided on cache startup in `start_link/2`.

  ## Examples

      iex> Cachex.stats(:my_cache)
      {:ok, %{meta: %{creation_date: 1518984857331}}}

      iex> Cachex.stats(:cache_with_no_stats)
      { :error, :stats_disabled }

  """
  @spec stats(Cachex.t(), Keyword.t()) :: {status, map()}
  def stats(cache, options \\ []) when is_list(options),
    do: Router.route(cache, {:stats, [options]})

  @doc """
  Creates a `Stream` of entries in a cache.

  This will stream all entries matching the match specification provided
  as the second argument. If none is provided, it will default to all entries
  which are yet to expire (in no particular order).

  Consider using `Cachex.Query` to generate match specifications used when
  querying the contents of a cache table.

  ## Options

    * `:buffer`

      Allows customization of the internal batching when paginating the cursor
      coming back from ETS. It's unlikely this will ever need changing.

  ## Examples

      iex> Cachex.put(:my_cache, "a", 1)
      iex> Cachex.put(:my_cache, "b", 2)
      iex> Cachex.put(:my_cache, "c", 3)
      {:ok, true}

      iex> :my_cache |> Cachex.stream! |> Enum.to_list
      [{:entry, "b", 1519015801794, nil, 2},
        {:entry, "c", 1519015805679, nil, 3},
        {:entry, "a", 1519015794445, nil, 1}]

      iex> query = Cachex.Query.build(output: :key)
      iex> :my_cache |> Cachex.stream!(query) |> Enum.to_list
      ["b", "c", "a"]

      iex> query = Cachex.Query.build(output: :value)
      iex> :my_cache |> Cachex.stream!(query) |> Enum.to_list
      [2, 3, 1]

      iex> query = Cachex.Query.build(output: {:key, :value})
      iex> :my_cache |> Cachex.stream!(query) |> Enum.to_list
      [{"b", 2}, {"c", 3}, {"a", 1}]

  """
  @spec stream(Cachex.t(), any, Keyword.t()) :: {status, Enumerable.t()}
  def stream(cache, query \\ Q.build(where: Q.unexpired()), options \\ [])
      when is_list(options),
      do: Router.route(cache, {:stream, [query, options]})

  @doc """
  Takes an entry from a cache.

  This is conceptually equivalent to running `get/3` followed
  by an atomic `del/3` call.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.take(:my_cache, "key")
      { :ok, "value" }

      iex> Cachex.get(:my_cache, "key")
      { :ok, nil }

      iex> Cachex.take(:my_cache, "missing_key")
      { :ok, nil }

  """
  @spec take(Cachex.t(), any, Keyword.t()) :: {status, any}
  def take(cache, key, options \\ []) when is_list(options),
    do: Router.route(cache, {:take, [key, options]})

  @doc """
  Updates the last write time on a cache entry.

  This is very similar to `refresh/3` except that the expiration
  time is maintained inside the record (using a calculated offset).
  """
  @spec touch(Cachex.t(), any, Keyword.t()) :: {status, boolean}
  def touch(cache, key, options \\ []) when is_list(options),
    do: Router.route(cache, {:touch, [key, options]})

  @doc """
  Executes multiple functions in the context of a transaction.

  This will operate in the same way as `execute/3`, except that writes
  to the specified keys will be blocked on the execution of this transaction.

  The keys parameter should be a list of keys you wish to lock whilst
  your transaction is executed. Any keys not in this list can still be
  written even during your transaction.

  ## Examples

      iex> Cachex.put(:my_cache, "key1", "value1")
      iex> Cachex.put(:my_cache, "key2", "value2")
      iex> Cachex.transaction(:my_cache, [ "key1", "key2" ], fn(worker) ->
      ...>   val1 = Cachex.get(worker, "key1")
      ...>   val2 = Cachex.get(worker, "key2")
      ...>   [val1, val2]
      ...> end)
      { :ok, [ "value1", "value2" ] }

  """
  @spec transaction(Cachex.t(), [any], function, Keyword.t()) :: {status, any}
  def transaction(cache, keys, operation, options \\ [])
      when is_function(operation) and is_list(keys) and is_list(options) do
    Overseer.with(cache, fn cache ->
      trans_cache =
        case cache(cache, :transactions) do
          true ->
            cache

          false ->
            cache
            |> cache(:name)
            |> Overseer.update(&cache(&1, transactions: true))
        end

      Router.route(trans_cache, {:transaction, [keys, operation, options]})
    end)
  end

  @doc """
  Retrieves the expiration for an entry in a cache.

  This is a millisecond value (if set) representing the time a
  cache entry has left to live in a cache. It can return `nil`
  if the entry does not have a set expiration.

  ## Examples

      iex> Cachex.ttl(:my_cache, "my_key")
      { :ok, 13985 }

      iex> Cachex.ttl(:my_cache, "my_key_with_no_ttl")
      { :ok, nil }

      iex> Cachex.ttl(:my_cache, "missing_key")
      { :ok, nil }

  """
  @spec ttl(Cachex.t(), any, Keyword.t()) :: {status, integer | nil}
  def ttl(cache, key, options \\ []) when is_list(options),
    do: Router.route(cache, {:ttl, [key, options]})

  @doc """
  Updates an entry in a cache.

  Unlike `get_and_update/4`, this does a blind overwrite of a value.

  This operation can be seen as an internal mutation, meaning that any previously
  set expiration time is kept as-is.

  ## Examples

      iex> Cachex.put(:my_cache, "key", "value")
      iex> Cachex.get(:my_cache, "key")
      { :ok, "value" }

      iex> Cachex.update(:my_cache, "key", "new_value")
      iex> Cachex.get(:my_cache, "key")
      { :ok, "new_value" }

      iex> Cachex.update(:my_cache, "missing_key", "new_value")
      { :ok, false }

  """
  @spec update(Cachex.t(), any, any, Keyword.t()) :: {status, any}
  def update(cache, key, value, options \\ []) when is_list(options),
    do: Router.route(cache, {:update, [key, value, options]})

  @doc """
  Triggers a manual warming in a cache.

  This allows for manual warming of a cache in situations where
  you already know the backing state has been updated. The return
  value of this function will contain the list of modules which
  were warmed as a result of this call.

  ## Options

    * `:only`

      An optional list of modules to warm, acting as a whitelist. The default
      behaviour of this function is to trigger warming in all modules. You may
      provide either the module name, or the registered warmer name.

    * `:wait`

      Whether to wait for warmer completion or not, as a boolean. By default
      warmers are triggered to run in the background, but passing `true` here
      will block the return of this call until all warmers have completed.

  ## Examples

      iex> Cachex.warm(:my_cache)
      { :ok, [MyWarmer] }

      iex> Cachex.warm(:my_cache, only: [MyWarmer])
      { :ok, [MyWarmer] }

      iex> Cachex.warm(:my_cache, only: [])
      { :ok, [] }

      iex> Cachex.warm(:my_cache, wait: true)
      { :ok, [MyWarmer]}

  """
  @spec warm(Cachex.t(), Keyword.t()) :: {status, [atom()]}
  def warm(cache, options \\ []),
    do: Router.route(cache, {:warm, [options]})

  ###############
  # Private API #
  ###############

  # Determines whether the Cachex application has been started.
  #
  # This will return an error if the application has not been
  # started, otherwise a truthy result will be returned.
  defp ensure_started do
    if Overseer.started?() do
      {:ok, true}
    else
      error(:not_started)
    end
  end

  # Determines if a cache name is already in use.
  #
  # If the name is in use, we return an error.
  defp ensure_unused(cache) do
    case GenServer.whereis(cache) do
      nil -> {:ok, true}
      pid -> {:error, {:already_started, pid}}
    end
  end

  # Initializes cache router on startup.
  #
  # This will initialize the base router state and attach all nodes
  # provided at cache startup to the router state.
  defp setup_router(cache(router: router) = cache) do
    router(module: module, options: options) = router

    state = module.init(cache, options)
    route = router(router, state: state)

    {:ok, cache(cache, router: route)}
  end

  # Initializes cache warmers on startup.
  #
  # This will trigger the initial cache warming via `Cachex.warm/2` while
  # also respecting whether certain warmers should block startup or not.
  defp setup_warmers(cache(warmers: warmers) = cache) do
    {req, opt} = Enum.split_with(warmers, &warmer(&1, :required))

    required = [only: Enum.map(req, &warmer(&1, :name)), wait: true]
    optional = [only: Enum.map(opt, &warmer(&1, :name)), wait: false]

    with {:ok, _} <- Cachex.warm(cache, const(:notify_false) ++ required),
         {:ok, _} <- Cachex.warm(cache, const(:notify_false) ++ optional) do
      :ok
    end
  end

  # Unwraps a command result into an unsafe form.
  #
  # This is used alongside the Unsafe library to generate shorthand
  # bang functions for the API. This will expand error messages and
  # remove the binding Tuples in order to allow for easy piping of
  # results from cache calls.
  defp unwrap_unsafe({:error, value}) when is_atom(value),
    do: raise(Cachex.Error, message: Cachex.Error.long_form(value))

  defp unwrap_unsafe({:error, value}) when is_binary(value),
    do: raise(Cachex.Error, message: value)

  defp unwrap_unsafe({:error, %Cachex.Error{stack: stack} = e}),
    do: reraise(e, stack)

  defp unwrap_unsafe({_state, value}),
    do: value
end
