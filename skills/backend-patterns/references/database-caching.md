# Database & Caching Patterns

## Query Optimization

```typescript
// GOOD: Select only needed columns
const { data } = await supabase
  .from('markets')
  .select('id, name, status, volume')
  .eq('status', 'active')
  .order('volume', { ascending: false })
  .limit(10)

// BAD: Select everything
const { data } = await supabase.from('markets').select('*')
```

## N+1 Query Prevention

```typescript
// BAD: N+1 query problem
const markets = await getMarkets()
for (const market of markets) {
  market.creator = await getUser(market.creator_id)  // N queries
}

// GOOD: Batch fetch
const markets = await getMarkets()
const creatorIds = markets.map(m => m.creator_id)
const creators = await getUsers(creatorIds)  // 1 query
const creatorMap = new Map(creators.map(c => [c.id, c]))
markets.forEach(market => {
  market.creator = creatorMap.get(market.creator_id)
})
```

## Transaction Pattern

```typescript
async function createMarketWithPosition(
  marketData: CreateMarketDto,
  positionData: CreatePositionDto
) {
  const { data, error } = await supabase.rpc('create_market_with_position', {
    market_data: marketData,
    position_data: positionData
  })
  if (error) throw new Error('Transaction failed')
  return data
}
```

## Redis Caching Layer (Cache-Aside Pattern)

```typescript
class CachedMarketRepository implements MarketRepository {
  constructor(
    private baseRepo: MarketRepository,
    private redis: RedisClient
  ) {}

  async findById(id: string): Promise<Market | null> {
    const cached = await this.redis.get(`market:${id}`)
    if (cached) return JSON.parse(cached)

    const market = await this.baseRepo.findById(id)
    if (market) {
      await this.redis.setex(`market:${id}`, 300, JSON.stringify(market))
    }
    return market
  }

  async invalidateCache(id: string): Promise<void> {
    await this.redis.del(`market:${id}`)
  }
}
```
