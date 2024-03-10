use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};

use aes_gcm_siv::AeadInPlace as _;
use ethers::middleware::Middleware;
use futures::stream::StreamExt as _;
use tokio::time::{sleep, Duration};
use tracing::{error, trace, warn};

use crate::{eth, identity::Identity, store::Store, types::*, utils::retry};

#[tracing::instrument(skip_all)]
pub async fn run<M: Middleware + 'static>(
    store: impl Store + 'static,
    sssss: impl Iterator<Item = eth::SsssPermitter<M>>,
    ssss_identity: Identity,
) -> Result<(), eth::Error<M>> {
    trace!("collating providers");

    for ssss in sssss {
        let store = store.clone();
        let chain = ssss.chain;
        trace!("launching task for chain {chain}");
        tokio::spawn(async move {
            let ssss = &ssss;
            loop {
                match sync_chain(chain, ssss, &store, &ssss_identity).await {
                    Ok(_) => warn!("sync task for chain {chain} unexpectedly exited"),
                    Err(e) => error!("sync task for chain {chain} exited with error: {e}"),
                }
                sleep(Duration::from_millis(1000)).await;
            }
        });
    }

    Ok(())
}

#[tracing::instrument(skip_all)]
async fn sync_chain<M: Middleware + 'static, S: Store + 'static>(
    chain_id: ChainId,
    permitter: &eth::SsssPermitter<M>,
    store: &S,
    ssss_identity: &Identity,
) -> Result<(), Error<M>> {
    let start_block = match store.get_chain_state(chain_id).await? {
        Some(ChainState { block }) => block,
        None => permitter.creation_block().await?,
    };

    let processed_block = Arc::new(AtomicU64::new(start_block));
    let state_updater_task = tokio::spawn({
        let store = store.clone();
        let processed_block = processed_block.clone();
        async move {
            loop {
                sleep(Duration::from_secs(5 * 60)).await;
                trace!("updating sync state for chain {chain_id}");
                if let Err(e) = store
                    .update_chain_state(
                        chain_id,
                        ChainStateUpdate {
                            block: Some(processed_block.load(Ordering::Acquire)),
                        },
                    )
                    .await
                {
                    warn!("failed to update sync state for chain {chain_id}: {e}");
                }
            }
        }
    });

    let processed_block = &processed_block;
    permitter
        .events(start_block, None)
        .buffered(1)
        .map(futures::stream::iter)
        .flatten()
        .for_each(|event| async move {
            trace!(event = ?event, "event");
            match event.kind {
                eth::EventKind::PolicyChange(eth::PolicyChange {
                    identity,
                    config: config_br,
                }) => {
                    let mut config = Vec::new();
                    if brotli_decompressor::BrotliDecompress(&mut config_br.as_slice(), &mut config)
                        .is_err()
                    {
                        warn!("failed to decompress config");
                        return;
                    }
                    retry(|| {
                        store.update_verifier(
                            PermitterLocator::new(chain_id, permitter.address),
                            identity,
                            config.clone(),
                            event.index,
                        )
                    })
                    .await;
                    trace!("set updated policy");
                }
                eth::EventKind::ProcessedBlock => {
                    processed_block.store(event.index.block, Ordering::Release);
                }
                eth::EventKind::SharesPosted(eth::SharesPosted {
                    identity,
                    pk,
                    nonce,
                    shares,
                    blindings,
                }) => {
                    let cipher = ssss_identity.derive_shared_cipher(pk);
                    let maybe_my_share = shares
                        .into_iter()
                        .zip(blindings.into_iter())
                        .enumerate()
                        .find_map(|(i, (enc_share, blinding))| {
                            let mut share = enc_share.to_vec();
                            cipher.decrypt_in_place(&nonce, &[], &mut share).ok()?;
                            Some((i as u64, share, blinding.to_vec()))
                        });
                    let (index, share, blinding) = match maybe_my_share {
                        Some(ss) => ss,
                        None => return,
                    };
                    let share = zeroize::Zeroizing::new(share);
                    retry(|| {
                        let share = share.clone();
                        let blinding = blinding.clone();
                        async move {
                            let put_share = store
                                .put_share(
                                    ShareId {
                                        identity: IdentityLocator {
                                            chain: chain_id,
                                            registry: permitter.registry().await?,
                                            id: identity,
                                        },
                                        version: 1,
                                    },
                                    SecretShare {
                                        index,
                                        share,
                                        blinding,
                                    },
                                )
                                .await?;
                            anyhow::ensure!(put_share, "share not put");
                            Ok(())
                        }
                    })
                    .await;
                }
            }
        })
        .await;

    state_updater_task.abort();
    Ok(())
}

#[derive(Debug, thiserror::Error)]
enum Error<M: Middleware> {
    #[error(transparent)]
    Store(#[from] crate::store::Error),
    #[error(transparent)]
    Eth(#[from] eth::Error<M>),
}
