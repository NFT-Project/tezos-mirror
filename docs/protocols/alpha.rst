Protocol Alpha
==============

This page documents the changes brought by protocol Alpha with respect
to Oxford (see :ref:`naming_convention`).

For changes brought by Oxford with respect to Nairobi, see :doc:`../protocols/018_oxford`.

The code can be found in directory :src:`src/proto_alpha` of the ``master``
branch of Octez.

.. contents::

Environment Version
-------------------


This protocol requires a different protocol environment version than Oxford.
It requires protocol environment V12, compared to V11 for Oxford.

Smart Rollups
-------------

- The unnecessary initial PVM state hash and its associated RPC are removed. (MR :gl:`!11472`)

Zero Knowledge Rollups (ongoing)
--------------------------------

Data Availability Layer (ongoing)
---------------------------------

- Introduced a new optional field ``dal_content`` to consensus
  attestation operations. The existing encoding of consensus
  attestations remains unchanged when this field is not present. A new
  encoding was introduced for the case when the field is present. The
  two cases are distinguished via an encoding tag. The newly
  introduced tag "23" must be used for attestations containing a DAL
  payload. (MR :gl:`!11462`).

- Introduced a new manager operation ``dal_publish_commitment``. This operation
  can be used to send a commitment over the data (to be send) over the DAL
  network. Do note that this operation itself does not contain the data
  themselves. Instead, it contains the slot index, the commitment over the data,
  and a proof regarding the size for those data. The data must be sent using the
  DAL node. For more information on how it works, please read the `DAL
  documentation <https://tezos.gitlab.io/shell/dal.html>`_.

- Optimize the DAL commitment publication operation by memoizing the
  cryptobox. (MR :gl:`!11594`)

- For smart-rollups: Introduced two reveal inputs. One for importing
  the data, called ``dal_page``. Data can be fed to the kernel by page
  of size 4096 bytes. Another reveal input named ``dal_parameters``
  enables kernel to read the DAL parameters. This should ease the
  writing of smart rollups kernels to make them generic over the
  values of those parameters. For more information on how it works,
  please read the `DAL smart rollup integration
  <https://tezos.gitlab.io/alpha/dal_support.html#smart-rollups-integration>`_.



Adaptive Issuance (ongoing)
----------------------------

- The staking balance is now explicitly initialized when a delegate is registered. (MR :gl:`!11197`)

- The issuance reward coeff is now computed only once.
  It used to be computed twice, once for the bonus, assuming a zero bonus, and once afterwards taking the bonus into account. (MR :gl:`!10935`)

- The minimal frozen stake is now checked before applying limits and then re-checked after applying limits and edge. (MR :gl:`!11086`)

- A delegate denounced for double baking or double attesting is now
  always forbidden from baking and attesting in the near future
  (previously, they were only forbidden if recent and incoming slashes
  summed up to at least 51% of their stake). This interdiction is
  lifted once all pending slashes have been applied and the delegate
  has enough frozen deposits to insure their baking rights for the
  next cycle. This will happen automatically
  ``consensus_right_delays`` (which is 2) cycles when rights computed
  right after the slash take effect, or possibly sooner if the
  delegate was overstaked or actively stakes more funds to match their
  previously computed rights. This change aims to protect bakers from
  incurring further penalties if a faulty configuration causes them to
  double bake/attest, by giving them some time to fix it. (MR
  :gl:`!11704`)

- Activating adaptive issuance per-block vote (MR !11935)

Gas improvements
----------------

Breaking Changes
----------------

RPC Changes
-----------

Operation receipts
------------------

Protocol parameters
-------------------

- replace ``preserved_cycles`` with 3 constants ``consensus_rights_delay``,
  ``blocks_preservation_cycles`` and
  ``delegate_parameters_activation_delay``. (MR :gl:`!11188`, :gl:`!11280`,
  :gl:`!11279`, :gl:`!11220`)

- Set the number of blocks preservation cycles to 1. (MR :gl:`!11325`)

Bug Fixes
---------

10s Blocks Time (MR :gl:`!11288`)
---------------------------------

Blocks time have been reduced from 15 seconds to 10 seconds. That is, a block
can be produced with a delay of 10 seconds with respect to the previous block,
if both blocks have round 0. This change comes with updating many related
protocol parameters in order to match the reduced blocks time. In particular,
the following quantities are kept the same:

- the minimal time period of a cycle (namely, 2 days, 20 hours, and 16 minutes),
- the length of the nonce revelation period (namely, around 2 hours and 8 minutes)
- the number of nonce commitments per cycle (namely, 128),
- the number of stake snapshots per cycle (namely, 16),
- the maximum rewards per minute (namely 80 tez), and therefore roughly the same inflation,
- the minimal "time to live" of an operation (namely, 1 hour),
- the block gas limit per minute (namely 10400000 gas),
- the ratio between the liquidity baking subsidy and the maximum rewards per block (namely, 1/16).

.. list-table:: Changes to protocol parameters
   :widths: 50 25 25
   :header-rows: 1

   * - Parameter (unit)
     - Old (oxford) value
     - New value
   * - ``minimal_block_delay`` (seconds)
     - ``15``
     - ``10``
   * - ``delay_increment_per_round`` (seconds)
     - ``8``
     - ``5``
   * - ``blocks_per_cycle`` (blocks)
     - ``16384``
     - ``24576``
   * - ``blocks_per_commitment`` (blocks)
     - ``128``
     - ``192``
   * - ``nonce_revelation_threshold`` (blocks)
     - ``512``
     - ``768``
   * - ``blocks_per_stake_snapshot`` (blocks)
     - ``1024``
     - ``1536``
   * - ``max_operations_time_to_live`` (blocks)
     - ``240``
     - ``360``
   * - ``hard_gas_limit_per_block`` (gas unit)
     - ``2600000``
     - ``1733333``


Minor Changes
-------------

- Michelson error traces for elaboration of invalid data was made more
  consistent by adding errors in some cases (BLS12-381 values, Sapling
  transactions, and timelocks). (MR :gl:`!10227`)

- A delegate may now be slashed once per double baking event and once
  per double (pre)attesting event at every level and round
  (previously, only at every level, no matter the round). (MR :gl:`!11826`)

Internal
--------

- On top of the 3 new parametric constants ``consensus_rights_delay``,
  ``blocks_preservation_cycles`` and ``delegate_parameters_activation_delay``
  which replace ``preserved_cycles``, we added pseudo-constants that derive from
  them : ``issuance_modification_delay``,
  ``adaptive_issuance_activation_delay``, ``tolerated_inactivity_period``,
  ``consensus_key_activation_delay``, ``slashable_deposits_period`` (MR
  :gl:`!11188`, :gl:`!11280`, :gl:`!11279`, :gl:`!11629`)
