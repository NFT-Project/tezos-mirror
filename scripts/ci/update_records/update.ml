open Tezt
open Base
open Tezt_gitlab

let section =
  Clap.section
    "UPDATE TEZT RECORDS"
    ~description:
      {|Update records in tezt/records by fetching them from a pipeline.

Example: to fetch test result records from https://gitlab.com/tezos/tezos/-/pipelines/426773806, run (from the root of the repository):

dune exec scripts/ci/update_records/update.exe -- --from 426773806

You can use the PROJECT environment variable to specify which GitLab repository to fetch records from. Default is: tezos/tezos

The script can also be used to fetch records from the last successful pipeline on the latest MR merged to the default branch (configurable through the DEFAULT_BRANCH environment variable) for a given PROJECT:

dune exec scripts/ci/update_records/update.exe -- --from last-merged-pipeline|}

let project = Sys.getenv_opt "PROJECT" |> Option.value ~default:"tezos/tezos"

let default_branch =
  Sys.getenv_opt "DEFAULT_BRANCH" |> Option.value ~default:"master"

let records_directory = "tezt/records"

let fetch_record (uri, index, kind) =
  let local_filename = index ^ ".json" in
  let local_dir = records_directory // kind in
  let local = local_dir // local_filename in
  if not @@ Sys.file_exists local_dir then Sys.mkdir local_dir 0o755 ;
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
    match name =~** rex "^tezt-?([^ ]*) (\\d+)/\\d+$" with
    | None -> None
    | Some (variant, index) ->
        let artifact_path =
          sf
            "tezt-results-%s%s.json"
            index
            (if variant = "" then ""
            else "-" ^ String.map (function '-' -> '_' | c -> c) variant)
        in
        Log.info "Will fetch %s from job #%d (%s)" artifact_path job_id name ;
        Some
          ( Gitlab.project_job_artifact ~project ~job_id ~artifact_path (),
            index,
            variant )
  in
  let records = List.filter_map get_record jobs in
  Log.info "Found %d Tezt jobs." (List.length records) ;
  (* Return the list of new records *)
  Lwt_list.map_p fetch_record records

type from = Pipeline of int | Last_merged_pipeline

let cli_from_type =
  let parse = function
    | "last-merged-pipeline" -> Some Last_merged_pipeline
    | s -> Option.map (fun x -> Pipeline x) (int_of_string_opt s)
  in
  let show = function
    | Pipeline id -> string_of_int id
    | Last_merged_pipeline -> "last-merged-pipeline"
  in
  Clap.typ ~name:"from" ~dummy:Last_merged_pipeline ~parse ~show

let cli_from =
  Clap.default
    cli_from_type
    ~section
    ~long:"from"
    ~placeholder:"PIPELINE"
    ~description:
      "The ID of the pipeline to fetch records from. Also accepts \
       'last-merged-pipeline', which denotes the last pipeline for the latest \
       merge commit on the default branch."
    Last_merged_pipeline

let () =
  (* Register a test to benefit from error handling of Test.run,
     as well as [Background.start] etc. *)
  ( Test.register ~__FILE__ ~title:"update records" ~tags:["update"] @@ fun () ->
    let* new_records =
      match cli_from with
      | Pipeline pipeline_id -> fetch_pipeline_records_from_jobs pipeline_id
      | Last_merged_pipeline ->
          let* pipeline_id =
            Gitlab_util.get_last_merged_pipeline ~project ~default_branch ()
          in
          fetch_pipeline_records_from_jobs pipeline_id
    in
    remove_existing_records new_records ;
    unit ) ;
  Test.run ()
