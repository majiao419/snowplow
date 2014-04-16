-- Copyright (c) 2014 Snowplow Analytics Ltd. All rights reserved.
--
-- This program is licensed to you under the Apache License Version 2.0,
-- and you may not use this file except in compliance with the Apache License Version 2.0.
-- You may obtain a copy of the Apache License Version 2.0 at http://www.apache.org/licenses/LICENSE-2.0.
--
-- Unless required by applicable law or agreed to in writing,
-- software distributed under the Apache License Version 2.0 is distributed on an
-- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the Apache License Version 2.0 for the specific language governing permissions and limitations there under.
--
-- Version:     0.1.0
-- URL:         -
--
-- Authors:     Alex Dean
-- Copyright:   Copyright (c) 2014 Snowplow Analytics Ltd
-- License:     Apache License Version 2.0

CREATE TABLE atomic.com_snowplowanalytics_link_click (
	-- Parentage of this type
	root_id      char(36)  encode raw not null,
	root_tstamp  timestamp encode raw not null,
	ref_root     varchar(128)  encode runlength not null,
	ref_ancestry varchar(1000) encode runlength not null,
	ref_parent   varchar(128)  encode runlength not null,
	-- Nature of this type
	type_name    varchar(128) encode runlength not null,
	type_vendor  varchar(128) encode runlength not null,
	-- Properties of this type
	element_id      varchar(255) encode text32k,
	element_classes varchar(2048) encode raw, -- Holds a JSON array. TODO: should reference off to 
	element_target  varchar(255) encode text255,
	target_url      varchar(4096) encode text32k not null, 
)
DISTSTYLE KEY
-- Optimized join to atomic.events
DISTKEY (root_id)
SORTKEY (root_tstamp);
