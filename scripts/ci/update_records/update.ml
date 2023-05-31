open Tezt
open Base
open Tezt_gitlab

let usage () =
  prerr_endline
    {|Usage: dune exec scripts/ci/update_records/update.exe -- -a from=[<PIPELINE_ID> | last-merged-pipeline]

Example: to fetch test result records from
https://gitlab.com/tezos/tezos/-/pipelines/426773806, run
(from the root of the repository):

dune exec scripts/ci/update_records/update.exe -- -a from=426773806

You can use the PROJECT environment variable to specify which GitLab
repository to fetch records from. Default is: tezos/tezos

The script can also be used to fetch records from the last successful pipeline on the
latest MR merged to the default branch (configurable through the DEFAULT_BRANCH
environment variable) for a given PROJECT:

dune exec scripts/ci/update_records/update.exe -- -a from=last-merged-pipeline

|} ;
  exit 1

let project = Sys.getenv_opt "PROJECT" |> Option.value ~default:"tezos/tezos"

let default_branch =
  Sys.getenv_opt "DEFAULT_BRANCH" |> Option.value ~default:"master"

let records_directory = "tezt/records"

let fetch_record (uri, index) =
  let local_filename = index ^ ".json" in
  let local = records_directory // local_filename in
  let* () = Gitlab.get_output uri ~output_path:local in
  Log.info "Downloaded: %s" local ;
  match JSON.parse_file local with
  | exception (JSON.Error _ as exn) ->
      Log.error
        "Failed to parse downloaded JSON file, maybe the artifact has expired?" ;
      raise exn
  | (_ : JSON.t) -> return local_filename

let remove_existing_records new_records =
  let remove_if_looks_like_an_old_record filename =
    if filename =~ rex "^\\d+\\.json$" && not (List.mem filename new_records)
    then (
      let filename = records_directory // filename in
      Sys.remove filename ;
      Log.info "Removed outdated record: %s" filename)
  in
  Array.iter remove_if_looks_like_an_old_record (Sys.readdir records_directory)

let fetch_pipeline_records_from_jobs pipeline =
  Log.info "Fetching records from tezt executions in %d in %s" pipeline project ;
  let* jobs = Gitlab.(project_pipeline_jobs ~project ~pipeline () |> get_all) in
  let get_record job =
    let job_id = JSON.(job |-> "id" |> as_int) in
    let name = JSON.(job |-> "name" |> as_string) in
    match name =~* rex "^tezt (\\d+)/\\d+$" with
    | None -> None
    | Some index ->
        Some
          ( Gitlab.project_job_artifact
              ~project
              ~job_id
              ~artifact_path:("tezt-results-" ^ index ^ ".json")
              (),
            index )
  in
  let records = List.filter_map get_record jobs in
  Log.info "Found %d Tezt jobs." (List.length records) ;
  (* Return the list of new records *)
  Lwt_list.map_p fetch_record records

let get_last_merged_pipeline () =
  let is_merge_commit commit =
    (* This script assumes that the start commit is part of a branch following
       a semi-linear history and that merged branches are linear (this should
       be the case for the default branch on tezos/tezos).  In that setting,
       only merge commits have two parents. *)
    List.length JSON.(commit |-> "parent_ids" |> as_list) = 2
  in
  Log.info
    "Searching for latest merge commit in project %s on branch %s"
    project
    default_branch ;
  let commit_hash commit = JSON.(commit |-> "id" |> as_string) in
  let* commits =
    Gitlab.(project_commits ~project ~ref_name:default_branch () |> get)
  in
  let commits = JSON.as_list commits in
  let rec aux = function
    | [] | [_] ->
        Test.fail
          "Could not find a merge commit in the last %d commits on '%s'"
          (List.length commits)
          default_branch
    | commit :: commit_parent :: commits ->
        if is_merge_commit commit then (
          Log.info "%s is a merge commit parent" (commit_hash commit_parent) ;
          let* pipelines =
            (* Fetches the latest pipelines by descending id. So the
               first element in the result should be the pipeline with
               the highest id and so most recent. *)
            Gitlab.(
              project_pipelines
                ~project
                ~order_by:"id"
                ~sort:"desc"
                ~sha:(commit_hash commit_parent)
                ()
              |> get)
          in
          match JSON.as_list pipelines with
          | pipeline :: _ ->
              let pipeline = JSON.(pipeline |-> "id" |> as_int) in
              Log.info
                "%s has a pipeline %d"
                (commit_hash commit_parent)
                pipeline ;
              return pipeline
          | [] ->
              Log.info "%s has no pipelines, skipping" (commit_hash commit) ;
              aux (commit_parent :: commits))
        else (
          Log.info "%s is not a merge commit, skipping" (commit_hash commit) ;
          aux (commit_parent :: commits))
  in
  aux commits

type from = Pipeline of int | Last_merged_pipeline

let cli_get_from =
  match Cli.get ~default:None (fun s -> Some (Some s)) "from" with
  | Some "last-merged-pipeline" -> Last_merged_pipeline
  | Some s -> (
      match int_of_string_opt s with Some i -> Pipeline i | None -> usage ())
  | None -> usage ()

let () =
  (* Register a test to benefit from error handling of Test.run,
     as well as [Background.start] etc. *)
  ( Test.register ~__FILE__ ~title:"update records" ~tags:["update"] @@ fun () ->
    let* new_records =
      match cli_get_from with
      | Pipeline pipeline_id -> fetch_pipeline_records_from_jobs pipeline_id
      | Last_merged_pipeline ->
          let* pipeline_id = get_last_merged_pipeline () in
          fetch_pipeline_records_from_jobs pipeline_id
    in
    remove_existing_records new_records ;
    unit ) ;
  Test.run ()
