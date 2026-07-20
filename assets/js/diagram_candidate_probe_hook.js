const DiagramCandidateProbe = {
  mounted() {
    this._probeGeneration = 0;
    this.handleEvent("probe_diagram_candidate", (payload) => this._probe(payload));
  },

  _probe({ candidate_ref: candidateRef, url }) {
    if (typeof candidateRef !== "string" || candidateRef === "" || typeof url !== "string" || url === "") {
      return;
    }

    const generation = ++this._probeGeneration;
    const image = new Image();
    const report = (result) => {
      if (generation !== this._probeGeneration) return;
      this.pushEvent("diagram_candidate_probe_result", { candidate_ref: candidateRef, result });
    };

    image.onload = () => report("ready");
    image.onerror = () => report("failed");
    image.src = url;
  },

  destroyed() {
    this._probeGeneration += 1;
  },
};

export default DiagramCandidateProbe;
