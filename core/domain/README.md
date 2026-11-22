<p align="center"><img src="assets/domain.svg" width="200" alt="Pure encounter decisions" /></p>

<h1 align="center">Pure encounter decisions</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

The pure encounter rules validate recording digests, sample rate, duration and continuity. Review requires the exact file selected by the clinician and rejects conflicting metadata. The store applies these rules while holding the recording row lock. Run `mix test` in this directory.
