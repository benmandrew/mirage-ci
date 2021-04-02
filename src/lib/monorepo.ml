open Current.Syntax

let pool = Current.Pool.create ~label:"monorepo-pool" 4

module Docker = Current_docker.Default

(********************************************)
(*****************  LOCK  *******************)
(********************************************)

type t = Docker.Image.t

let v ~system ~repos =
  Current_solver.v ~system ~repos ~packages:[ "opam-monorepo" ]
  |> Setup.tools_image ~system ~name:"opam-monorepo tool"

let add_repos repos =
  let open Dockerfile in
  let repo_add (name, commit) = run "opam repo add %s %s" name (Setup.remote_uri commit) in
  List.fold_left ( @@ ) (run "opam repo remove local") (List.map repo_add repos)

let pp_wrap =
  Fmt.using (String.split_on_char '\n')
    Fmt.(list ~sep:(unit " \\@\n    ") (using String.trim string))

let lock ~repos ~opam t =
  let dockerfile =
    let+ t = t and+ opam = opam and+ repos = repos in
    let open Dockerfile in
    from (Docker.Image.hash t)
    @@ user "opam"
    @@ add_repos repos 
    @@ copy ~chown:"opam" ~src:[ "." ] ~dst:"/src" ()
    @@ workdir "/src"
    @@ run "echo '%s' >> monorepo.opam" (Fmt.str "%a" pp_wrap (Opamfile.marshal opam))
    @@ run "opam monorepo lock -l monorepo.opam.locked"
    |> fun dockerfile -> `Contents dockerfile
  in
  let image = Docker.build ~dockerfile ~label:"opam monorepo lock" ~pool ~pull:false `No_context in
  Current.component "monorepo lockfile"
  |> let** lockfile_str =
       Docker.pread ~label:"lockfile" ~args:[ "cat"; "/src/monorepo.opam.locked" ] image
     in
     let lockfile = OpamParser.string lockfile_str "monorepo.opam.locked" in
     let packages = Opamfile.get_packages lockfile in
     let+ dev_repos_str =
       Docker.pread ~label:"dev repos"
         ~args:
           ( [ "opam"; "show"; "--field"; "name:,dev-repo:" ]
           @ List.map (fun (pkg : Opamfile.pkg) -> pkg.name ^ "." ^ pkg.version) packages )
         image
     in
     Monorepo_lock.make ~opam_file:lockfile
       ~dev_repo_output:(String.split_on_char '\n' dev_repos_str)

let lock ~value ~repos ~opam t =
  Current.collapse ~key:"monorepo-lock" ~value ~input:opam (lock ~repos ~opam t)

(********************************************)
(***************   SPEC       ***************)
(********************************************)

let spec ~base ~lock () =
  let+ lock = lock and+ base = base in
  let opamfile = Monorepo_lock.lockfile lock in
  let open Obuilder_spec in
  base
  |> Spec.add (Setup.install_tools [ "dune"; "opam-monorepo" ])
  |> Spec.add
       [
         workdir "/src";
         run "sudo chown opam:opam /src";
         run "echo '%s' >> monorepo.opam" (Opamfile.marshal opamfile);
         (* depexts  *)
         run "opam pin -n add monorepo . --locked --ignore-pin-depends";
         run ~network:Setup.network "opam depext --update -y monorepo";
         run "opam pin -n remove monorepo";
         (* setup lockfile *)
         run "cp monorepo.opam monorepo.opam.locked";
         run ~network:Setup.network "opam exec -- opam monorepo pull -y -l  monorepo.opam.locked";
       ]

(********************************************)
(********************************************)
(********************************************)

let opam_file ~ocaml_version (projects : Universe.Project.t list) =
  let pp_project f (proj : Universe.Project.t) =
    List.iter (fun opam -> Fmt.pf f "\"%s\"\n" opam.Universe.name) proj.opam
  in
  Fmt.str
    {|
opam-version: "2.0"
depends: [
  "ocaml" { = "%s"}
  %a
]
conflicts: [
  "parsexp" { < "v0.14.0"}
  "sexplib" { < "v0.14.0"}
  "base" { < "v0.14.0"}
]
|}
    ocaml_version (Fmt.list pp_project) projects
  |> Opamfile.unmarshal
