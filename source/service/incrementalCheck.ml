(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Ast
open Analysis
open Pyre

type errors = Analysis.AnalysisError.t list [@@deriving show]

let recheck ~configuration ~scheduler ~environment ~errors artifact_paths =
  let timer = Timer.start () in
  let annotated_global_environment = TypeEnvironment.global_environment environment in
  Scheduler.once_per_worker scheduler ~configuration ~f:SharedMemory.invalidate_caches;
  SharedMemory.invalidate_caches ();
  SharedMemory.collect `aggressive;
  (* Repopulate the environment. *)
  Log.info "Repopulating the environment...";

  let annotated_global_environment_update_result =
    AnnotatedGlobalEnvironment.update_this_and_all_preceding_environments
      annotated_global_environment
      ~scheduler
      artifact_paths
  in
  let invalidated_modules =
    AnnotatedGlobalEnvironment.UpdateResult.invalidated_modules
      annotated_global_environment_update_result
  in
  let unannotated_global_environment_update_result =
    AnnotatedGlobalEnvironment.UpdateResult.unannotated_global_environment_update_result
      annotated_global_environment_update_result
  in
  let function_triggers =
    let filter_union sofar keyset =
      let filter registered sofar =
        match SharedMemoryKeys.DependencyKey.get_key registered with
        | SharedMemoryKeys.TypeCheckDefine name -> (
            match Reference.Map.add sofar ~key:name ~data:registered with
            | `Duplicate -> sofar
            | `Ok updated -> updated)
        | _ -> sofar
      in
      SharedMemoryKeys.DependencyKey.RegisteredSet.fold filter keyset sofar
    in
    AnnotatedGlobalEnvironment.UpdateResult.all_triggered_dependencies
      annotated_global_environment_update_result
    |> List.fold ~init:Reference.Map.empty ~f:filter_union
  in
  let recheck_functions =
    let register_and_add sofar trigger =
      let register = function
        | Some existing -> existing
        | None ->
            SharedMemoryKeys.DependencyKey.Registry.register
              (SharedMemoryKeys.TypeCheckDefine trigger)
      in
      Reference.Map.update sofar trigger ~f:register
    in
    UnannotatedGlobalEnvironment.UpdateResult.define_additions
      unannotated_global_environment_update_result
    |> Set.fold ~init:function_triggers ~f:register_and_add
  in
  let recheck_functions_list = Map.to_alist recheck_functions in
  let recheck_function_names = List.map recheck_functions_list ~f:fst in

  (* Rerun type checking for triggered functions. *)
  TypeEnvironment.invalidate environment recheck_function_names;
  recheck_functions_list
  |> List.map ~f:(fun (define, registered) -> define, Some registered)
  |> TypeEnvironment.populate_for_definitions ~scheduler ~configuration environment;

  (* Rerun postprocessing for triggered modules. *)
  let recheck_modules =
    (* For each rechecked function, its containing module needs to be included in postprocessing *)
    List.fold
      ~init:(Reference.Set.of_list invalidated_modules)
      (Reference.Map.keys function_triggers)
      ~f:(fun sofar define_name ->
        let unannotated_global_environment =
          TypeEnvironment.read_only environment
          |> TypeEnvironment.ReadOnly.unannotated_global_environment
        in
        match
          UnannotatedGlobalEnvironment.ReadOnly.get_function_definition
            unannotated_global_environment
            define_name
        with
        | None -> sofar
        | Some { FunctionDefinition.qualifier; _ } -> Set.add sofar qualifier)
    |> Set.to_list
  in

  let new_errors =
    Analysis.Postprocessing.run
      ~scheduler
      ~configuration
      ~environment:(Analysis.TypeEnvironment.read_only environment)
      recheck_modules
  in
  let rechecked_functions_count = Map.length recheck_functions in
  Statistics.event
    ~section:`Memory
    ~name:"shared memory size"
    ~integers:["size", Memory.heap_size ()]
    ();

  (* Kill all previous errors for new files we just checked *)
  List.iter ~f:(Hashtbl.remove errors) recheck_modules;

  (* Associate the new errors with new files *)
  Log.info "Number of new errors = %d" (List.length new_errors);
  List.iter new_errors ~f:(fun error ->
      let key = AnalysisError.module_reference error in
      Hashtbl.add_multi errors ~key ~data:error);

  let module_updates =
    UnannotatedGlobalEnvironment.UpdateResult.module_updates
      unannotated_global_environment_update_result
  in
  Statistics.performance
    ~name:"incremental check"
    ~timer
    ~integers:
      [
        "number of changed files", List.length artifact_paths;
        "number of module tracker updates", List.length module_updates;
        "number of parser updates", List.length invalidated_modules;
        "number of rechecked modules", List.length recheck_modules;
        "number of re-checked functions", rechecked_functions_count;
      ]
    ();
  recheck_modules, new_errors
