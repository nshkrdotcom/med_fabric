# `MedFabric.Interop.FhirClient`

Exports a reviewed recording to FHIR R4 using conditional create by identifier.

The test server receives synthetic clinical references. Fixture origin and
continuity describe the reviewed artifact independently of those references.

# `build_observation`

```elixir
@spec build_observation(map(), map(), map(), keyword()) :: map()
```

# `deliver`

```elixir
@spec deliver(map(), keyword()) :: {:ok, map()} | {:error, term()}
```

# `fetch_by_identifier`

```elixir
@spec fetch_by_identifier(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
```

# `seed_exam`

```elixir
@spec seed_exam(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
```

Seeds a synthetic patient and encounter using stable identifiers on the receiving server.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
