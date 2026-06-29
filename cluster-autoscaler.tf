// Cluster-level autoscaling for the GKE e2-pool node pool.
//
// The cluster itself is NOT managed by this Terraform 
// We document the autoscaler config here as an out-of-band note
// so future operators know how to reproduce the state.
//
// Enabled via:
//   gcloud container clusters update misarch \
//     --zone=europe-west1-b \
//     --enable-autoscaling \
//     --min-nodes=1 --max-nodes=2 \
//     --node-pool=e2-pool
//
// Rationale (CNAE / right-sizing companion change):
//   After right-sizing pod requests across all 24 misarch services, the
//   cluster's CPU-allocation footprint dropped enough to fit on a single
//   e2-standard-8 during S0 idle. With autoscaler min=1 max=2, GKE will drain
//   one node when allocation drops below ~80 % of single-node capacity, then
//   restore the second node under S2 peak. Expected idle-time win: ~50 W
//   (entire VM goes off-billing).
//
// Verification: `gcloud container node-pools list --cluster=misarch
//                --zone=europe-west1-b --format='value(autoscaling)'`
