(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Pyre

module type ReadOnly = sig
  type t

  val unannotated_global_environment : t -> UnannotatedGlobalEnvironment.ReadOnly.t
end

module UpdateResult = struct
  module type S = sig
    type t

    val locally_triggered_dependencies : t -> SharedMemoryKeys.DependencyKey.RegisteredSet.t

    val all_triggered_dependencies : t -> SharedMemoryKeys.DependencyKey.RegisteredSet.t list

    val unannotated_global_environment_update_result
      :  t ->
      UnannotatedGlobalEnvironment.UpdateResult.t

    val invalidated_modules : t -> Ast.Reference.t list
  end
end

module PreviousEnvironment = struct
  module type S = sig
    module ReadOnly : ReadOnly

    module UpdateResult : UpdateResult.S

    type t

    val create : Configuration.Analysis.t -> t

    val create_for_testing : Configuration.Analysis.t -> (Ast.ModulePath.t * string) list -> t

    val ast_environment : t -> AstEnvironment.t

    val configuration : t -> Configuration.Analysis.t

    val read_only : t -> ReadOnly.t

    val update_this_and_all_preceding_environments
      :  t ->
      scheduler:Scheduler.t ->
      ArtifactPath.t list ->
      UpdateResult.t

    val store : t -> unit

    val load : Configuration.Analysis.t -> t
  end
end

module type S = sig
  include PreviousEnvironment.S

  module PreviousEnvironment : PreviousEnvironment.S

  module Testing : sig
    module ReadOnly : sig
      val upstream : ReadOnly.t -> PreviousEnvironment.ReadOnly.t
    end

    module UpdateResult : sig
      val upstream : UpdateResult.t -> PreviousEnvironment.UpdateResult.t
    end
  end
end

module EnvironmentTable = struct
  module type In = sig
    module PreviousEnvironment : PreviousEnvironment.S

    module Key : Memory.KeyType

    module Value : Memory.ComparableValueType

    type trigger [@@deriving sexp, compare]

    val convert_trigger : trigger -> Key.t

    val key_to_trigger : Key.t -> trigger

    module TriggerSet : Set.S with type Elt.t = trigger

    val lazy_incremental : bool

    val filter_upstream_dependency : SharedMemoryKeys.dependency -> trigger option

    val trigger_to_dependency : trigger -> SharedMemoryKeys.dependency

    val produce_value
      :  PreviousEnvironment.ReadOnly.t ->
      trigger ->
      dependency:SharedMemoryKeys.DependencyKey.registered option ->
      Value.t

    val serialize_value : Value.t -> string

    val show_key : Key.t -> string

    val equal_value : Value.t -> Value.t -> bool
  end

  module type Table = sig
    include Memory.FirstClass.NoCache.S

    val add_to_transaction
      :  t ->
      SharedMemoryKeys.DependencyKey.Transaction.t ->
      keys:KeySet.t ->
      SharedMemoryKeys.DependencyKey.Transaction.t

    val add_pessimistic_transaction
      :  t ->
      SharedMemoryKeys.DependencyKey.Transaction.t ->
      keys:KeySet.t ->
      SharedMemoryKeys.DependencyKey.Transaction.t

    val get : t -> ?dependency:SharedMemoryKeys.DependencyKey.registered -> key -> value option

    val mem : t -> ?dependency:SharedMemoryKeys.DependencyKey.registered -> key -> bool
  end

  module type S = sig
    module In : In

    module ReadOnly : sig
      type t

      val get : t -> ?dependency:SharedMemoryKeys.DependencyKey.registered -> In.Key.t -> In.Value.t

      val upstream_environment : t -> In.PreviousEnvironment.ReadOnly.t

      val unannotated_global_environment : t -> UnannotatedGlobalEnvironment.ReadOnly.t
    end

    module UpdateResult : UpdateResult.S

    type t

    val create : Configuration.Analysis.t -> t

    val create_for_testing : Configuration.Analysis.t -> (Ast.ModulePath.t * string) list -> t

    val ast_environment : t -> AstEnvironment.t

    val configuration : t -> Configuration.Analysis.t

    val read_only : t -> ReadOnly.t

    val update_this_and_all_preceding_environments
      :  t ->
      scheduler:Scheduler.t ->
      ArtifactPath.t list ->
      UpdateResult.t

    val store : t -> unit

    val load : Configuration.Analysis.t -> t

    module Testing : sig
      module ReadOnly : sig
        val upstream : ReadOnly.t -> In.PreviousEnvironment.ReadOnly.t
      end

      module UpdateResult : sig
        val upstream : UpdateResult.t -> In.PreviousEnvironment.UpdateResult.t
      end
    end
  end

  module Make (In : In) (Table : Table with type value = In.Value.t and type key = In.Key.t) =
  struct
    let _ = Table.mem

    module In = In

    module ReadOnly = struct
      type t = {
        get: ?dependency:SharedMemoryKeys.DependencyKey.registered -> In.Key.t -> In.Value.t;
        upstream_environment: In.PreviousEnvironment.ReadOnly.t;
      }

      let get { get; _ } = get

      let upstream_environment { upstream_environment; _ } = upstream_environment

      let unannotated_global_environment { upstream_environment; _ } =
        In.PreviousEnvironment.ReadOnly.unannotated_global_environment upstream_environment
    end

    module UpdateResult = struct
      type t = {
        upstream: In.PreviousEnvironment.UpdateResult.t;
        triggered_dependencies: SharedMemoryKeys.DependencyKey.RegisteredSet.t;
      }

      let locally_triggered_dependencies { triggered_dependencies; _ } = triggered_dependencies

      let all_triggered_dependencies { triggered_dependencies; upstream; _ } =
        triggered_dependencies
        :: In.PreviousEnvironment.UpdateResult.all_triggered_dependencies upstream


      let unannotated_global_environment_update_result { upstream; _ } =
        In.PreviousEnvironment.UpdateResult.unannotated_global_environment_update_result upstream


      let invalidated_modules previous =
        unannotated_global_environment_update_result previous
        |> UnannotatedGlobalEnvironment.UpdateResult.invalidated_modules
    end

    module FromReadOnlyUpstream = struct
      type t = {
        table: Table.t;
        upstream_environment: In.PreviousEnvironment.ReadOnly.t;
      }

      let create upstream_environment = { table = Table.create (); upstream_environment }

      let get { table; upstream_environment } ?dependency key =
        match Table.get table ?dependency key with
        | Some hit -> hit
        | None ->
            let trigger = In.key_to_trigger key in
            let dependency = In.trigger_to_dependency trigger in
            let dependency = Some (SharedMemoryKeys.DependencyKey.Registry.register dependency) in
            let value = In.produce_value upstream_environment trigger ~dependency in
            Table.add table key value;
            value


      let read_only ({ upstream_environment; _ } as this_environment) =
        { ReadOnly.get = get this_environment; upstream_environment }


      module TriggerMap = Map.Make (struct
        type t = In.trigger [@@deriving sexp, compare]
      end)

      let compute_trigger_map upstream_triggered_dependencies =
        List.fold
          upstream_triggered_dependencies
          ~init:TriggerMap.empty
          ~f:(fun triggers upstream_dependencies ->
            SharedMemoryKeys.DependencyKey.RegisteredSet.fold
              (fun dependency triggers ->
                match
                  In.filter_upstream_dependency (SharedMemoryKeys.DependencyKey.get_key dependency)
                with
                | Some trigger -> (
                    match TriggerMap.add triggers ~key:trigger ~data:dependency with
                    | `Duplicate -> triggers
                    | `Ok updated -> updated)
                | None -> triggers)
              upstream_dependencies
              triggers)


      let update_only_this_environment ~scheduler { table; upstream_environment } trigger_map =
        Log.log ~section:`Environment "Updating %s Environment" In.Value.description;
        let update ~names_to_update () =
          let register () =
            let set (name, dependency) =
              In.produce_value upstream_environment name ~dependency:(Some dependency)
              |> Table.add table (In.convert_trigger name)
            in
            List.iter ~f:set
          in
          let () =
            SharedMemoryKeys.DependencyKey.Registry.collected_map_reduce
              scheduler
              ~policy:
                (Scheduler.Policy.fixed_chunk_count
                   ~minimum_chunks_per_worker:1
                   ~minimum_chunk_size:100
                   ~preferred_chunks_per_worker:5
                   ())
              ~map:register
              ~reduce:(fun () () -> ())
              ~inputs:names_to_update
              ~initial:()
              ()
          in
          ()
        in
        let triggered_dependencies =
          let name = Format.sprintf "TableUpdate(%s)" In.Value.description in
          Profiling.track_duration_and_shared_memory_with_dynamic_tags name ~f:(fun _ ->
              let names_to_update = Map.to_alist trigger_map in
              let (), triggered_dependencies =
                let keys =
                  List.map names_to_update ~f:fst
                  |> List.map ~f:In.convert_trigger
                  |> Table.KeySet.of_list
                in
                let transaction = SharedMemoryKeys.DependencyKey.Transaction.empty ~scheduler in
                if In.lazy_incremental then
                  Table.add_pessimistic_transaction table ~keys transaction
                  |> SharedMemoryKeys.DependencyKey.Transaction.execute ~update:(fun () -> ())
                else
                  Table.add_to_transaction table ~keys transaction
                  |> SharedMemoryKeys.DependencyKey.Transaction.execute
                       ~update:(update ~names_to_update)
              in
              let tags () =
                let triggered_dependencies_size =
                  SharedMemoryKeys.DependencyKey.RegisteredSet.cardinal triggered_dependencies
                  |> Format.sprintf "%d"
                in
                [
                  "phase_name", In.Value.description;
                  "number_of_triggered_dependencies", triggered_dependencies_size;
                ]
              in
              { Profiling.result = triggered_dependencies; tags })
        in
        triggered_dependencies
    end

    module Base = struct
      type t = {
        upstream_environment: In.PreviousEnvironment.t;
        from_read_only_upstream: FromReadOnlyUpstream.t;
      }

      let from_upstream_environment upstream_environment =
        {
          upstream_environment;
          from_read_only_upstream =
            In.PreviousEnvironment.read_only upstream_environment |> FromReadOnlyUpstream.create;
        }


      let create configuration =
        In.PreviousEnvironment.create configuration |> from_upstream_environment


      let create_for_testing configuration module_path_code_pairs =
        In.PreviousEnvironment.create_for_testing configuration module_path_code_pairs
        |> from_upstream_environment


      let configuration { upstream_environment; _ } =
        In.PreviousEnvironment.configuration upstream_environment


      let ast_environment { upstream_environment; _ } =
        In.PreviousEnvironment.ast_environment upstream_environment


      let read_only { from_read_only_upstream; _ } =
        FromReadOnlyUpstream.read_only from_read_only_upstream


      let update_this_and_all_preceding_environments
          { upstream_environment; from_read_only_upstream }
          ~scheduler
          artifact_paths
        =
        let upstream_update =
          In.PreviousEnvironment.update_this_and_all_preceding_environments
            upstream_environment
            ~scheduler
            artifact_paths
        in
        let triggered_dependencies =
          In.PreviousEnvironment.UpdateResult.all_triggered_dependencies upstream_update
          |> FromReadOnlyUpstream.compute_trigger_map
          |> FromReadOnlyUpstream.update_only_this_environment from_read_only_upstream ~scheduler
        in
        { UpdateResult.triggered_dependencies; upstream = upstream_update }


      (* All SharedMemory tables are populated and stored in separate, imperative steps that must be
         run after storing / before loading These functions only handle serializing and
         deserializing the non-SharedMemory data *)

      let store { upstream_environment; _ } = In.PreviousEnvironment.store upstream_environment

      let load configuration =
        In.PreviousEnvironment.load configuration |> from_upstream_environment
    end

    include Base

    module Testing = struct
      module ReadOnly = struct
        let upstream { ReadOnly.upstream_environment; _ } = upstream_environment
      end

      module UpdateResult = struct
        let upstream { UpdateResult.upstream; _ } = upstream
      end
    end
  end

  module WithCache (In : In) =
    Make
      (In)
      (DependencyTrackedMemory.DependencyTrackedTableWithCache
         (In.Key)
         (SharedMemoryKeys.DependencyKey)
         (In.Value))
  module NoCache (In : In) =
    Make
      (In)
      (DependencyTrackedMemory.DependencyTrackedTableNoCache
         (In.Key)
         (SharedMemoryKeys.DependencyKey)
         (In.Value))
end
